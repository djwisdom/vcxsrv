%{
/*
 * Copyright © 2008, 2009 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
#include <ctype.h>
#include <limits.h>
#include "util/strtod.h"
#include "ast.h"
#include "glsl_parser_extras.h"
#include "glsl_parser.hpp"
#include "main/consts_exts.h"

static int classify_identifier(struct _mesa_glsl_parse_state *, const char *,
			       unsigned name_len, YYSTYPE *output);

#ifdef _MSC_VER
#define YY_NO_UNISTD_H
#endif

#define YY_NO_INPUT
#define YY_USER_ACTION						\
   do {								\
      yylloc->first_column = yycolumn + 1;			\
      yylloc->first_line = yylloc->last_line = yylineno + 1;	\
      yycolumn += yyleng;					\
      yylloc->last_column = yycolumn + 1;			\
   } while(0);

#define YY_USER_INIT yylineno = 0; yycolumn = 0; yylloc->source = 0; \
   yylloc->path = NULL;

/* A macro for handling reserved words and keywords across language versions.
 *
 * Certain words start out as identifiers, become reserved words in
 * later language revisions, and finally become language keywords.
 * This may happen at different times in desktop GLSL and GLSL ES.
 *
 * For example, consider the following lexer rule:
 * samplerBuffer       KEYWORD(130, 0, 140, 0, SAMPLERBUFFER)
 *
 * This means that "samplerBuffer" will be treated as:
 * - a keyword (SAMPLERBUFFER token)         ...in GLSL >= 1.40
 * - a reserved word - error                 ...in GLSL >= 1.30
 * - an identifier                           ...in GLSL <  1.30 or GLSL ES
 */
#define KEYWORD(reserved_glsl, reserved_glsl_es,			\
                allowed_glsl, allowed_glsl_es, token)			\
   KEYWORD_WITH_ALT(reserved_glsl, reserved_glsl_es,			\
                    allowed_glsl, allowed_glsl_es, false, token)

/**
 * Like the KEYWORD macro, but the word is also treated as a keyword
 * if the given boolean expression is true.
 */
#define KEYWORD_WITH_ALT(reserved_glsl, reserved_glsl_es,		\
                         allowed_glsl, allowed_glsl_es,			\
                         alt_expr, token)				\
   do {									\
      if (yyextra->is_version(allowed_glsl, allowed_glsl_es)		\
          || (alt_expr)) {						\
	 return token;							\
      } else if (yyextra->is_version(reserved_glsl,			\
                                     reserved_glsl_es)) {		\
	 _mesa_glsl_error(yylloc, yyextra,				\
			  "illegal use of reserved word `%s'", yytext);	\
	 return ERROR_TOK;						\
      } else {								\
	 return classify_identifier(yyextra, yytext, yyleng, yylval);	\
      }									\
   } while (0)

/**
 * Like KEYWORD_WITH_ALT, but used for built-in GLSL types
 */
#define TYPE_WITH_ALT(reserved_glsl, reserved_glsl_es,			\
		      allowed_glsl, allowed_glsl_es,			\
		      alt_expr, gtype)					\
   do {									\
      if (yyextra->is_version(allowed_glsl, allowed_glsl_es)		\
          || (alt_expr)) {						\
	 yylval->type = gtype; 						\
	 return BASIC_TYPE_TOK;						\
      } else if (yyextra->is_version(reserved_glsl,			\
                                     reserved_glsl_es)) {		\
	 _mesa_glsl_error(yylloc, yyextra,				\
			  "illegal use of reserved word `%s'", yytext);	\
	 return ERROR_TOK;						\
      } else {								\
	 return classify_identifier(yyextra, yytext, yyleng, yylval);	\
      }									\
   } while (0)

#define TYPE(reserved_glsl, reserved_glsl_es,				\
             allowed_glsl, allowed_glsl_es,				\
             gtype)							\
   TYPE_WITH_ALT(reserved_glsl, reserved_glsl_es,			\
                 allowed_glsl, allowed_glsl_es,				\
                 false, gtype)

/**
 * A macro for handling keywords that have been present in GLSL since
 * its origin, but were changed into reserved words in later versions.
 */
#define DEPRECATED_KEYWORD(token, state, reserved_glsl,			\
                           reserved_glsl_es)				\
   do {									\
      if (yyextra->is_version(reserved_glsl, reserved_glsl_es) &&	\
          !state->compat_shader) {					\
	 _mesa_glsl_error(yylloc, yyextra,				\
			  "illegal use of reserved word `%s'", yytext);	\
	 return ERROR_TOK;						\
      } else {								\
         return token;							\
      }									\
   } while (0)

/**
 * Like DEPRECATED_KEYWORD, but for types
 */
#define DEPRECATED_ES_TYPE_WITH_ALT(alt_expr, gtype)			\
   do {									\
      if (yyextra->is_version(0, 300)) {				\
         _mesa_glsl_error(yylloc, yyextra,				\
                          "illegal use of reserved word `%s'", yytext);	\
         return ERROR_TOK;						\
      } else if (alt_expr) {						\
         yylval->type = gtype;						\
         return BASIC_TYPE_TOK;						\
      } else {								\
         return classify_identifier(yyextra, yytext, yyleng, yylval);	\
      }									\
   } while (0)

#define DEPRECATED_ES_TYPE(gtype)					\
   DEPRECATED_ES_TYPE_WITH_ALT(true, gtype)

static int
literal_integer(char *text, int len, struct _mesa_glsl_parse_state *state,
		YYSTYPE *lval, YYLTYPE *lloc, int base)
{
   bool is_uint = (text[len - 1] == 'u' ||
		   text[len - 1] == 'U');
   bool is_long = (text[len - 1] == 'l' || text[len - 1] == 'L');
   const char *digits = text;

   if (is_long)
      is_uint = (text[len - 2] == 'u' && text[len - 1] == 'l') ||
                (text[len - 2] == 'U' && text[len - 1] == 'L');
   /* Skip "0x" */
   if (base == 16)
      digits += 2;

   unsigned long long value = strtoull(digits, NULL, base);

   if (is_long)
      lval->n64 = (int64_t)value;
   else
      lval->n = (int)value;

   if (is_long && !is_uint && base == 10 && value > (uint64_t)LLONG_MAX + 1) {
      /* Tries to catch unintentionally providing a negative value. */
      _mesa_glsl_warning(lloc, state,
                         "signed literal value `%s' is interpreted as %lld",
                         text, lval->n64);
   } else if (!is_long && value > UINT_MAX) {
      /* Note that signed 0xffffffff is valid, not out of range! */
      if (state->is_version(130, 300)) {
	 _mesa_glsl_error(lloc, state,
			  "literal value `%s' out of range", text);
      } else {
	 _mesa_glsl_warning(lloc, state,
			    "literal value `%s' out of range", text);
      }
   } else if (base == 10 && !is_uint && (unsigned)value > (unsigned)INT_MAX + 1) {
      /* Tries to catch unintentionally providing a negative value.
       * Note that -2147483648 is parsed as -(2147483648), so we don't
       * want to warn for INT_MAX.
       */
      _mesa_glsl_warning(lloc, state,
			 "signed literal value `%s' is interpreted as %d",
			 text, lval->n);
   }
   if (is_long)
      return is_uint ? UINT64CONSTANT : INT64CONSTANT;
   else
      return is_uint ? UINTCONSTANT : INTCONSTANT;
}

#define LITERAL_INTEGER(base) \
   literal_integer(yytext, yyleng, yyextra, yylval, yylloc, base)

%}

%option bison-bridge bison-locations reentrant noyywrap
%option nounput noyy_top_state
%option never-interactive
%option prefix="_mesa_glsl_lexer_"
%option extra-type="struct _mesa_glsl_parse_state *"
%option warn nodefault

	/* Note: When adding any start conditions to this list, you must also
	 * update the "Internal compiler error" catch-all rule near the end of
	 * this file. */
%x PP PRAGMA

DEC_INT		[1-9][0-9]*
HEX_INT		0[xX][0-9a-fA-F]+
OCT_INT		0[0-7]*
INT		({DEC_INT}|{HEX_INT}|{OCT_INT})
SPC		[ \t]*
SPCP		[ \t]+
HASH		^{SPC}#{SPC}
PATH		["][./ _A-Za-z0-9]*["]
%%

[ \r\t]+		;

    /* Preprocessor tokens. */
^[ \t]*#[ \t]*$			;
^[ \t]*#[ \t]*version		{ BEGIN PP; return VERSION_TOK; }
^[ \t]*#[ \t]*extension		{ BEGIN PP; return EXTENSION; }
{HASH}include {
                                  if (!yyextra->ARB_shading_language_include_enable) {
                                     struct _mesa_glsl_parse_state *state = yyextra;
                                     _mesa_glsl_error(yylloc, state,
                                                      "ARB_shading_language_include required "
                                                      "to use #include");
                                   }
}
{HASH}line{SPCP}{INT}{SPCP}{INT}{SPC}$ {
				   /* Eat characters until the first digit is
				    * encountered
				    */
				   char *ptr = yytext;
				   while (!isdigit(*ptr))
				      ptr++;

				   /* Subtract one from the line number because
				    * yylineno is zero-based instead of
				    * one-based.
				    */
				   yylineno = strtol(ptr, &ptr, 0) - 1;

                                   /* From GLSL 3.30 and GLSL ES on, after processing the
                                    * line directive (including its new-line), the implementation
                                    * will behave as if it is compiling at the line number passed
                                    * as argument. It was line number + 1 in older specifications.
                                    */
                                   if (yyextra->is_version(330, 100))
                                      yylineno--;

				   yylloc->source = strtol(ptr, NULL, 0);
                                   yylloc->path = NULL;
				}
{HASH}line{SPCP}{INT}{SPCP}{PATH}{SPC}$ {
                                   if (!yyextra->ARB_shading_language_include_enable) {
                                      struct _mesa_glsl_parse_state *state = yyextra;
                                      _mesa_glsl_error(yylloc, state,
                                                       "ARB_shading_language_include required "
                                                       "to use #line <line> \"<path>\"");
                                   }

                                   /* Eat characters until the first digit is
                                    * encountered
                                    */
                                   char *ptr = yytext;
                                   while (!isdigit(*ptr))
                                      ptr++;

                                   /* Subtract one from the line number because
                                    * yylineno is zero-based instead of
                                    * one-based.
                                    */
                                   yylineno = strtol(ptr, &ptr, 0) - 1;

                                   /* From GLSL 3.30 and GLSL ES on, after processing the
                                    * line directive (including its new-line), the implementation
                                    * will behave as if it is compiling at the line number passed
                                    * as argument. It was line number + 1 in older specifications.
                                    */
                                   if (yyextra->is_version(330, 100))
                                      yylineno--;

                                   while (isspace(*ptr))
                                      ptr++;

                                   /* Skip over leading " */
                                   ptr++;

                                   char *end = strrchr(ptr, '"');
                                   int path_len = (end - ptr) + 1;
                                   linear_ctx *mem_ctx = yyextra->linalloc;
                                   yylloc->path = (char *) linear_alloc_child(mem_ctx, path_len);
                                   memcpy(yylloc->path, ptr, path_len);
                                   yylloc->path[path_len - 1] = '\0';
                                }
{HASH}line{SPCP}{INT}{SPC}$	{
				   /* Eat characters until the first digit is
				    * encountered
				    */
				   char *ptr = yytext;
				   while (!isdigit(*ptr))
				      ptr++;

				   /* Subtract one from the line number because
				    * yylineno is zero-based instead of
				    * one-based.
				    */
				   yylineno = strtol(ptr, &ptr, 0) - 1;

                                   /* From GLSL 3.30 and GLSL ES on, after processing the
                                    * line directive (including its new-line), the implementation
                                    * will behave as if it is compiling at the line number passed
                                    * as argument. It was line number + 1 in older specifications.
                                    */
                                   if (yyextra->is_version(330, 100))
                                      yylineno--;
				}
^{SPC}#{SPC}pragma{SPCP}debug{SPC}\({SPC}on{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_DEBUG_ON;
				}
^{SPC}#{SPC}pragma{SPCP}debug{SPC}\({SPC}off{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_DEBUG_OFF;
				}
^{SPC}#{SPC}pragma{SPCP}optimize{SPC}\({SPC}on{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_OPTIMIZE_ON;
				}
^{SPC}#{SPC}pragma{SPCP}optimize{SPC}\({SPC}off{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_OPTIMIZE_OFF;
				}
^{SPC}#{SPC}pragma{SPCP}warning{SPC}\({SPC}on{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_WARNING_ON;
				}
^{SPC}#{SPC}pragma{SPCP}warning{SPC}\({SPC}off{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_WARNING_OFF;
				}
^{SPC}#{SPC}pragma{SPCP}STDGL{SPCP}invariant{SPC}\({SPC}all{SPC}\) {
				  BEGIN PP;
				  return PRAGMA_INVARIANT_ALL;
				}
^{SPC}#{SPC}pragma{SPCP}	{ BEGIN PRAGMA; }

<PRAGMA>\n			{ BEGIN 0; yylineno++; yycolumn = 0; }
<PRAGMA>.			{ }

<PP>\/\/[^\n]*			{ }
<PP>[ \t\r]*			{ }
<PP>:				return COLON;
<PP>[_a-zA-Z][_a-zA-Z0-9]*	{
				   /* We're not doing linear_strdup here, to avoid an implicit call
				    * on strlen() for the length of the string, as this is already
				    * found by flex and stored in yyleng
				    */
                                    linear_ctx *mem_ctx = yyextra->linalloc;
                                    char *id = (char *) linear_alloc_child(mem_ctx, yyleng + 1);
                                    memcpy(id, yytext, yyleng + 1);
                                    yylval->identifier = id;
				   return IDENTIFIER;
				}
<PP>[1-9][0-9]*			{
				    yylval->n = strtol(yytext, NULL, 10);
				    return INTCONSTANT;
				}
<PP>0				{
				    yylval->n = 0;
				    return INTCONSTANT;
				}
<PP>\n				{ BEGIN 0; yylineno++; yycolumn = 0; return EOL; }
<PP>.				{ return yytext[0]; }

\n		{ yylineno++; yycolumn = 0; }

attribute	DEPRECATED_KEYWORD(ATTRIBUTE, yyextra, 420, 300);
const		return CONST_TOK;
bool		{ yylval->type = &glsl_type_builtin_bool; return BASIC_TYPE_TOK; }
float		{ yylval->type = &glsl_type_builtin_float; return BASIC_TYPE_TOK; }
int		{ yylval->type = &glsl_type_builtin_int; return BASIC_TYPE_TOK; }
uint		TYPE(130, 300, 130, 300, &glsl_type_builtin_uint);

break		return BREAK;
continue	return CONTINUE;
do		return DO;
while		return WHILE;
else		return ELSE;
for		return FOR;
if		return IF;
discard		return DISCARD;
return		return RETURN;
demote		KEYWORD_WITH_ALT(0, 0, 0, 0, yyextra->EXT_demote_to_helper_invocation_enable, DEMOTE);

bvec2		{ yylval->type = &glsl_type_builtin_bvec2; return BASIC_TYPE_TOK; }
bvec3		{ yylval->type = &glsl_type_builtin_bvec3; return BASIC_TYPE_TOK; }
bvec4		{ yylval->type = &glsl_type_builtin_bvec4; return BASIC_TYPE_TOK; }
ivec2		{ yylval->type = &glsl_type_builtin_ivec2; return BASIC_TYPE_TOK; }
ivec3		{ yylval->type = &glsl_type_builtin_ivec3; return BASIC_TYPE_TOK; }
ivec4		{ yylval->type = &glsl_type_builtin_ivec4; return BASIC_TYPE_TOK; }
uvec2		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable, &glsl_type_builtin_uvec2);
uvec3		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable, &glsl_type_builtin_uvec3);
uvec4		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable, &glsl_type_builtin_uvec4);
vec2		{ yylval->type = &glsl_type_builtin_vec2; return BASIC_TYPE_TOK; }
vec3		{ yylval->type = &glsl_type_builtin_vec3; return BASIC_TYPE_TOK; }
vec4		{ yylval->type = &glsl_type_builtin_vec4; return BASIC_TYPE_TOK; }
mat2		{ yylval->type = &glsl_type_builtin_mat2; return BASIC_TYPE_TOK; }
mat3		{ yylval->type = &glsl_type_builtin_mat3; return BASIC_TYPE_TOK; }
mat4		{ yylval->type = &glsl_type_builtin_mat4; return BASIC_TYPE_TOK; }
mat2x2		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat2);
mat2x3		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat2x3);
mat2x4		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat2x4);
mat3x2		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat3x2);
mat3x3		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat3);
mat3x4		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat3x4);
mat4x2		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat4x2);
mat4x3		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat4x3);
mat4x4		TYPE(120, 300, 120, 300, &glsl_type_builtin_mat4);

in		return IN_TOK;
out		return OUT_TOK;
inout		return INOUT_TOK;
uniform		return UNIFORM;
buffer		KEYWORD_WITH_ALT(0, 0, 430, 310, yyextra->ARB_shader_storage_buffer_object_enable, BUFFER);
varying		DEPRECATED_KEYWORD(VARYING, yyextra, 420, 300);
centroid	KEYWORD_WITH_ALT(120, 300, 120, 300, yyextra->EXT_gpu_shader4_enable, CENTROID);
invariant	KEYWORD(120, 100, 120, 100, INVARIANT);
flat		KEYWORD_WITH_ALT(130, 100, 130, 300, yyextra->EXT_gpu_shader4_enable, FLAT);
smooth		KEYWORD(130, 300, 130, 300, SMOOTH);
noperspective	KEYWORD_WITH_ALT(130, 300, 130, 0, yyextra->EXT_gpu_shader4_enable || yyextra->NV_shader_noperspective_interpolation_enable, NOPERSPECTIVE);
patch		KEYWORD_WITH_ALT(0, 300, 400, 320, yyextra->has_tessellation_shader(), PATCH);

sampler1D	DEPRECATED_ES_TYPE(&glsl_type_builtin_sampler1D);
sampler2D	{ yylval->type = &glsl_type_builtin_sampler2D; return BASIC_TYPE_TOK; }
sampler3D	{ yylval->type = &glsl_type_builtin_sampler3D; return BASIC_TYPE_TOK; }
samplerCube	{ yylval->type = &glsl_type_builtin_samplerCube; return BASIC_TYPE_TOK; }
sampler1DArray	TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_array, &glsl_type_builtin_sampler1DArray);
sampler2DArray	TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_array, &glsl_type_builtin_sampler2DArray);
sampler1DShadow	DEPRECATED_ES_TYPE(&glsl_type_builtin_sampler1DShadow);
sampler2DShadow	{ yylval->type = &glsl_type_builtin_sampler2DShadow; return BASIC_TYPE_TOK; }
samplerCubeShadow	TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable, &glsl_type_builtin_samplerCubeShadow);
sampler1DArrayShadow	TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_array, &glsl_type_builtin_sampler1DArrayShadow);
sampler2DArrayShadow	TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_array, &glsl_type_builtin_sampler2DArrayShadow);
isampler1D		TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_isampler1D);
isampler2D		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_isampler2D);
isampler3D		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_isampler3D);
isamplerCube		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_isamplerCube);
isampler1DArray		TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer && yyextra->exts->EXT_texture_array, &glsl_type_builtin_isampler1DArray);
isampler2DArray		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer && yyextra->exts->EXT_texture_array, &glsl_type_builtin_isampler2DArray);
usampler1D		TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_usampler1D);
usampler2D		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_usampler2D);
usampler3D		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_usampler3D);
usamplerCube		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_usamplerCube);
usampler1DArray		TYPE_WITH_ALT(130, 300, 130, 0,   yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer && yyextra->exts->EXT_texture_array, &glsl_type_builtin_usampler1DArray);
usampler2DArray		TYPE_WITH_ALT(130, 300, 130, 300, yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_integer && yyextra->exts->EXT_texture_array, &glsl_type_builtin_usampler2DArray);

   /* additional keywords in ARB_texture_multisample, included in GLSL 1.50 */
   /* these are reserved but not defined in GLSL 3.00 */
   /* [iu]sampler2DMS are defined in GLSL ES 3.10 */
sampler2DMS        TYPE_WITH_ALT(150, 300, 150, 310, yyextra->ARB_texture_multisample_enable, &glsl_type_builtin_sampler2DMS);
isampler2DMS       TYPE_WITH_ALT(150, 300, 150, 310, yyextra->ARB_texture_multisample_enable, &glsl_type_builtin_isampler2DMS);
usampler2DMS       TYPE_WITH_ALT(150, 300, 150, 310, yyextra->ARB_texture_multisample_enable, &glsl_type_builtin_usampler2DMS);
sampler2DMSArray   TYPE_WITH_ALT(150, 300, 150, 320, yyextra->ARB_texture_multisample_enable || yyextra->OES_texture_storage_multisample_2d_array_enable, &glsl_type_builtin_sampler2DMSArray);
isampler2DMSArray  TYPE_WITH_ALT(150, 300, 150, 320, yyextra->ARB_texture_multisample_enable || yyextra->OES_texture_storage_multisample_2d_array_enable, &glsl_type_builtin_isampler2DMSArray);
usampler2DMSArray  TYPE_WITH_ALT(150, 300, 150, 320, yyextra->ARB_texture_multisample_enable || yyextra->OES_texture_storage_multisample_2d_array_enable, &glsl_type_builtin_usampler2DMSArray);

   /* keywords available with ARB_texture_cube_map_array_enable extension on desktop GLSL */
samplerCubeArray   TYPE_WITH_ALT(400, 310, 400, 320, yyextra->ARB_texture_cube_map_array_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_samplerCubeArray);
isamplerCubeArray TYPE_WITH_ALT(400, 310, 400, 320, yyextra->ARB_texture_cube_map_array_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_isamplerCubeArray);
usamplerCubeArray TYPE_WITH_ALT(400, 310, 400, 320, yyextra->ARB_texture_cube_map_array_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_usamplerCubeArray);
samplerCubeArrayShadow   TYPE_WITH_ALT(400, 310, 400, 320, yyextra->ARB_texture_cube_map_array_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_samplerCubeArrayShadow);

samplerExternalOES		{
			  if (yyextra->OES_EGL_image_external_enable || yyextra->OES_EGL_image_external_essl3_enable) {
			     yylval->type = &glsl_type_builtin_samplerExternalOES;
			     return BASIC_TYPE_TOK;
			  } else
			     return IDENTIFIER;
		}

   /* keywords available with ARB_gpu_shader5 */
precise		KEYWORD_WITH_ALT(400, 310, 400, 320, yyextra->ARB_gpu_shader5_enable || yyextra->EXT_gpu_shader5_enable || yyextra->OES_gpu_shader5_enable, PRECISE);

   /* keywords available with ARB_shader_image_load_store */
image1D         TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image1D);
image2D         TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image2D);
image3D         TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image3D);
image2DRect     TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image2DRect);
imageCube       TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_imageCube);
imageBuffer     TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable, &glsl_type_builtin_imageBuffer);
image1DArray    TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image1DArray);
image2DArray    TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image2DArray);
imageCubeArray  TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_imageCubeArray);
image2DMS       TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image2DMS);
image2DMSArray  TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_image2DMSArray);
iimage1D        TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage1D);
iimage2D        TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage2D);
iimage3D        TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage3D);
iimage2DRect    TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage2DRect);
iimageCube      TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimageCube);
iimageBuffer    TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable, &glsl_type_builtin_iimageBuffer);
iimage1DArray   TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage1DArray);
iimage2DArray   TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage2DArray);
iimageCubeArray TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_iimageCubeArray);
iimage2DMS      TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage2DMS);
iimage2DMSArray TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_iimage2DMSArray);
uimage1D        TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage1D);
uimage2D        TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage2D);
uimage3D        TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage3D);
uimage2DRect    TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage2DRect);
uimageCube      TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimageCube);
uimageBuffer    TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable, &glsl_type_builtin_uimageBuffer);
uimage1DArray   TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage1DArray);
uimage2DArray   TYPE_WITH_ALT(130, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage2DArray);
uimageCubeArray TYPE_WITH_ALT(130, 300, 420, 320, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->OES_texture_cube_map_array_enable || yyextra->EXT_texture_cube_map_array_enable, &glsl_type_builtin_uimageCubeArray);
uimage2DMS      TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage2DMS);
uimage2DMSArray TYPE_WITH_ALT(130, 300, 420, 0, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable, &glsl_type_builtin_uimage2DMSArray);
image1DShadow           KEYWORD(130, 0, 420, 0, IMAGE1DSHADOW);
image2DShadow           KEYWORD(130, 0, 420, 0, IMAGE2DSHADOW);
image1DArrayShadow      KEYWORD(130, 0, 420, 0, IMAGE1DARRAYSHADOW);
image2DArrayShadow      KEYWORD(130, 0, 420, 0, IMAGE2DARRAYSHADOW);

coherent       KEYWORD_WITH_ALT(420, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->ARB_shader_storage_buffer_object_enable, COHERENT);
volatile       KEYWORD_WITH_ALT(110, 100, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->ARB_shader_storage_buffer_object_enable, VOLATILE);
restrict       KEYWORD_WITH_ALT(420, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->EXT_shader_image_load_store_enable || yyextra->ARB_shader_storage_buffer_object_enable, RESTRICT);
readonly       KEYWORD_WITH_ALT(420, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->ARB_shader_storage_buffer_object_enable, READONLY);
writeonly      KEYWORD_WITH_ALT(420, 300, 420, 310, yyextra->ARB_shader_image_load_store_enable || yyextra->ARB_shader_storage_buffer_object_enable, WRITEONLY);

atomic_uint     TYPE_WITH_ALT(420, 300, 420, 310, yyextra->ARB_shader_atomic_counters_enable, &glsl_type_builtin_atomic_uint);

shared          KEYWORD_WITH_ALT(430, 310, 430, 310, yyextra->ARB_compute_shader_enable, SHARED);

struct		return STRUCT;
void		return VOID_TOK;

layout		{
		  if ((yyextra->is_version(140, 300))
		      || yyextra->ARB_bindless_texture_enable
		      || yyextra->KHR_blend_equation_advanced_enable
		      || yyextra->AMD_conservative_depth_enable
		      || yyextra->ARB_conservative_depth_enable
		      || yyextra->EXT_conservative_depth_enable
		      || yyextra->ARB_explicit_attrib_location_enable
		      || yyextra->ARB_explicit_uniform_location_enable
                      || yyextra->ARB_post_depth_coverage_enable
                      || yyextra->has_separate_shader_objects()
		      || yyextra->ARB_uniform_buffer_object_enable
		      || yyextra->ARB_fragment_coord_conventions_enable
                      || yyextra->ARB_shading_language_420pack_enable
                      || yyextra->ARB_compute_shader_enable
                      || yyextra->ARB_tessellation_shader_enable
                      || yyextra->EXT_shader_framebuffer_fetch_non_coherent_enable
                      || yyextra->OVR_multiview_enable) {
		      return LAYOUT_TOK;
		   } else {
		      return classify_identifier(yyextra, yytext, yyleng, yylval);
		   }
		}

\+\+		return INC_OP;
--		return DEC_OP;
\<=		return LE_OP;
>=		return GE_OP;
==		return EQ_OP;
!=		return NE_OP;
&&		return AND_OP;
\|\|		return OR_OP;
"^^"		return XOR_OP;
"<<"		return LEFT_OP;
">>"		return RIGHT_OP;

\*=		return MUL_ASSIGN;
\/=		return DIV_ASSIGN;
\+=		return ADD_ASSIGN;
\%=		return MOD_ASSIGN;
\<\<=		return LEFT_ASSIGN;
>>=		return RIGHT_ASSIGN;
&=		return AND_ASSIGN;
"^="		return XOR_ASSIGN;
\|=		return OR_ASSIGN;
-=		return SUB_ASSIGN;

[1-9][0-9]*([uU]|[lL]|ul|UL)?	{
			    return LITERAL_INTEGER(10);
			}
0[xX][0-9a-fA-F]+([uU]|[lL]|ul|UL)?	{
			    return LITERAL_INTEGER(16);
			}
0[0-7]*([uU]|[lL]|ul|UL)?		{
			    return LITERAL_INTEGER(8);
			}

[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?(hf|HF)	|
\.[0-9]+([eE][+-]?[0-9]+)?(hf|HF)	|
[0-9]+\.([eE][+-]?[0-9]+)?(hf|HF)	|
[0-9]+[eE][+-]?[0-9]+(hf|HF)		{
			    if (!yyextra->AMD_gpu_shader_half_float_enable)
			        return ERROR_TOK;
			    yylval->dreal = _mesa_strtod(yytext, NULL);
			    return FLOAT16CONSTANT;
			}

[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?[fF]?	|
\.[0-9]+([eE][+-]?[0-9]+)?[fF]?		|
[0-9]+\.([eE][+-]?[0-9]+)?[fF]?		|
[0-9]+[eE][+-]?[0-9]+[fF]?		{
			    struct _mesa_glsl_parse_state *state = yyextra;
			    char suffix = yytext[strlen(yytext) - 1];
			    if (!state->is_version(120, 300) &&
			        (suffix == 'f' || suffix == 'F')) {
			        _mesa_glsl_warning(yylloc, state,
			                           "Float suffixes are invalid in GLSL 1.10");
			    }
			    yylval->real = _mesa_strtof(yytext, NULL);
			    return FLOATCONSTANT;
			}

[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?(lf|LF)	|
\.[0-9]+([eE][+-]?[0-9]+)?(lf|LF)	|
[0-9]+\.([eE][+-]?[0-9]+)?(lf|LF)	|
[0-9]+[eE][+-]?[0-9]+(lf|LF)		{
			    if (!yyextra->is_version(400, 0) &&
			        !yyextra->ARB_gpu_shader_fp64_enable)
			        return ERROR_TOK;
			    yylval->dreal = _mesa_strtod(yytext, NULL);
			    return DOUBLECONSTANT;
			}

true			{
			    yylval->n = 1;
			    return BOOLCONSTANT;
			}
false			{
			    yylval->n = 0;
			    return BOOLCONSTANT;
			}


    /* Reserved words in GLSL 1.10. */
asm		KEYWORD(110, 100, 0, 0, ASM);
class		KEYWORD(110, 100, 0, 0, CLASS);
union		KEYWORD(110, 100, 0, 0, UNION);
enum		KEYWORD(110, 100, 0, 0, ENUM);
typedef		KEYWORD(110, 100, 0, 0, TYPEDEF);
template	KEYWORD(110, 100, 0, 0, TEMPLATE);
this		KEYWORD(110, 100, 0, 0, KW_THIS);
packed		KEYWORD_WITH_ALT(110, 100, 140, 300, yyextra->ARB_uniform_buffer_object_enable, PACKED_TOK);
goto		KEYWORD(110, 100, 0, 0, GOTO);
switch		KEYWORD(110, 100, 130, 300, SWITCH);
default		KEYWORD(110, 100, 130, 300, DEFAULT);
inline		KEYWORD(110, 100, 0, 0, INLINE_TOK);
noinline	KEYWORD(110, 100, 0, 0, NOINLINE);
public		KEYWORD(110, 100, 0, 0, PUBLIC_TOK);
static		KEYWORD(110, 100, 0, 0, STATIC);
extern		KEYWORD(110, 100, 0, 0, EXTERN);
external	KEYWORD(110, 100, 0, 0, EXTERNAL);
interface	KEYWORD(110, 100, 0, 0, INTERFACE_TOK);
long		KEYWORD(110, 100, 0, 0, LONG_TOK);
short		KEYWORD(110, 100, 0, 0, SHORT_TOK);
double		TYPE_WITH_ALT(130, 100, 130, 300, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_double);
half		KEYWORD(110, 100, 0, 0, HALF);
fixed		KEYWORD(110, 100, 0, 0, FIXED_TOK);
unsigned	KEYWORD_WITH_ALT(110, 100, 0, 0, yyextra->EXT_gpu_shader4_enable, UNSIGNED);
input		KEYWORD(110, 100, 0, 0, INPUT_TOK);
output		KEYWORD(110, 100, 0, 0, OUTPUT);
hvec2		KEYWORD(110, 100, 0, 0, HVEC2);
hvec3		KEYWORD(110, 100, 0, 0, HVEC3);
hvec4		KEYWORD(110, 100, 0, 0, HVEC4);
dvec2		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dvec2);
dvec3		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dvec3);
dvec4		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dvec4);
dmat2		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat2);
dmat3		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat3);
dmat4		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat4);
dmat2x2		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat2);
dmat2x3		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat2x3);
dmat2x4		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat2x4);
dmat3x2		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat3x2);
dmat3x3		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat3);
dmat3x4		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat3x4);
dmat4x2		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat4x2);
dmat4x3		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat4x3);
dmat4x4		TYPE_WITH_ALT(110, 100, 400, 0, yyextra->ARB_gpu_shader_fp64_enable, &glsl_type_builtin_dmat4);
fvec2		KEYWORD(110, 100, 0, 0, FVEC2);
fvec3		KEYWORD(110, 100, 0, 0, FVEC3);
fvec4		KEYWORD(110, 100, 0, 0, FVEC4);
sampler2DRect 		TYPE_WITH_ALT(110, 100, 0, 0, yyextra->ARB_texture_rectangle_enable, &glsl_type_builtin_sampler2DRect);
sampler3DRect		KEYWORD(110, 100, 0, 0, SAMPLER3DRECT);
sampler2DRectShadow	TYPE_WITH_ALT(110, 100, 0, 0, yyextra->ARB_texture_rectangle_enable, &glsl_type_builtin_sampler2DRectShadow);
sizeof		KEYWORD(110, 100, 0, 0, SIZEOF);
cast		KEYWORD(110, 100, 0, 0, CAST);
namespace	KEYWORD(110, 100, 0, 0, NAMESPACE);
using		KEYWORD(110, 100, 0, 0, USING);

    /* Additional reserved words in GLSL 1.20. */
lowp		KEYWORD(120, 100, 130, 100, LOWP);
mediump		KEYWORD(120, 100, 130, 100, MEDIUMP);
highp		KEYWORD(120, 100, 130, 100, HIGHP);
precision	KEYWORD(120, 100, 130, 100, PRECISION);

    /* Additional reserved words in GLSL 1.30. */
case		KEYWORD(130, 300, 130, 300, CASE);
common		KEYWORD(130, 300, 0, 0, COMMON);
partition	KEYWORD(130, 300, 0, 0, PARTITION);
active		KEYWORD(130, 300, 0, 0, ACTIVE);
superp		KEYWORD(130, 100, 0, 0, SUPERP);
samplerBuffer	TYPE_WITH_ALT(130, 300, 140, 320, yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable || (yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_buffer_object), &glsl_type_builtin_samplerBuffer);
filter		KEYWORD(130, 300, 0, 0, FILTER);
row_major	KEYWORD_WITH_ALT(130, 0, 140, 0, yyextra->ARB_uniform_buffer_object_enable && !yyextra->es_shader, ROW_MAJOR);

    /* Additional reserved words in GLSL 1.40 */
isampler2DRect	TYPE_WITH_ALT(140, 300, 140, 0, yyextra->EXT_gpu_shader4_enable && yyextra->exts->NV_texture_rectangle && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_isampler2DRect);
usampler2DRect	TYPE_WITH_ALT(140, 300, 140, 0, yyextra->EXT_gpu_shader4_enable && yyextra->exts->NV_texture_rectangle && yyextra->exts->EXT_texture_integer, &glsl_type_builtin_usampler2DRect);
isamplerBuffer	TYPE_WITH_ALT(140, 300, 140, 320, yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable || (yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_buffer_object && yyextra->exts->EXT_texture_integer), &glsl_type_builtin_isamplerBuffer);
usamplerBuffer	TYPE_WITH_ALT(140, 300, 140, 320, yyextra->EXT_texture_buffer_enable || yyextra->OES_texture_buffer_enable || (yyextra->EXT_gpu_shader4_enable && yyextra->exts->EXT_texture_buffer_object && yyextra->exts->EXT_texture_integer), &glsl_type_builtin_usamplerBuffer);

    /* Additional reserved words in GLSL ES 3.00 */
resource	KEYWORD(420, 300, 0, 0, RESOURCE);
sample		KEYWORD_WITH_ALT(400, 300, 400, 320, yyextra->ARB_gpu_shader5_enable || yyextra->OES_shader_multisample_interpolation_enable, SAMPLE);
subroutine	KEYWORD_WITH_ALT(400, 300, 400, 0, yyextra->ARB_shader_subroutine_enable, SUBROUTINE);

    /* Additional words for ARB_gpu_shader_int64 */
int64_t		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_int64_t);
i64vec2		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_i64vec2);
i64vec3		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_i64vec3);
i64vec4		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_i64vec4);

uint64_t	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_uint64_t);
u64vec2		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_u64vec2);
u64vec3		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_u64vec3);
u64vec4		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->ARB_gpu_shader_int64_enable || yyextra->AMD_gpu_shader_int64_enable, &glsl_type_builtin_u64vec4);

    /* Additional words for AMD_gpu_shader_half_float */
float16_t	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_float16_t);
f16vec2		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16vec2);
f16vec3		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16vec3);
f16vec4		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16vec4);
f16mat2		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat2);
f16mat3		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat3);
f16mat4		TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat4);
f16mat2x2	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat2);
f16mat2x3	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat2x3);
f16mat2x4	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat2x4);
f16mat3x2	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat3x2);
f16mat3x3	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat3);
f16mat3x4	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat3x4);
f16mat4x2	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat4x2);
f16mat4x3	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat4x3);
f16mat4x4	TYPE_WITH_ALT(0, 0, 0, 0, yyextra->AMD_gpu_shader_half_float_enable, &glsl_type_builtin_f16mat4);

[_a-zA-Z][_a-zA-Z0-9]*	{
			    struct _mesa_glsl_parse_state *state = yyextra;
			    if (state->es_shader && yyleng > 1024) {
			       _mesa_glsl_error(yylloc, state,
			                        "Identifier `%s' exceeds 1024 characters",
			                        yytext);
			    }
			    return classify_identifier(state, yytext, yyleng, yylval);
			}

\.			{ struct _mesa_glsl_parse_state *state = yyextra;
			  state->is_field = true;
			  return DOT_TOK; }

.			{ return yytext[0]; }

%%

int
classify_identifier(struct _mesa_glsl_parse_state *state, const char *name,
                    unsigned name_len, YYSTYPE *output)
{
   /* We're not doing linear_strdup here, to avoid an implicit call on
    * strlen() for the length of the string, as this is already found by flex
    * and stored in yyleng
    */
   char *id = (char *) linear_alloc_child(state->linalloc, name_len + 1);
   memcpy(id, name, name_len + 1);
   output->identifier = id;

   if (state->is_field) {
      state->is_field = false;
      return FIELD_SELECTION;
   }
   if (state->symbols->get_variable(name) || state->symbols->get_function(name))
      return IDENTIFIER;
   else if (state->symbols->get_type(name))
      return TYPE_IDENTIFIER;
   else
      return NEW_IDENTIFIER;
}

void
_mesa_glsl_lexer_ctor(struct _mesa_glsl_parse_state *state, const char *string)
{
   yylex_init_extra(state, & state->scanner);
   yy_scan_string(string, state->scanner);
}

void
_mesa_glsl_lexer_dtor(struct _mesa_glsl_parse_state *state)
{
   yylex_destroy(state->scanner);
}

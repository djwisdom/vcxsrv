LIBRARY=librootless

DEFINES += PIXMAN_API=
INCLUDES += ../.. ../../dix

librootless_la_SOURCES = \
	rootlessCommon.c \
	rootlessGC.c \
	rootlessScreen.c \
	rootlessValTree.c \
	rootlessWindow.c

CSRCS = $(filter %.c,$(librootless_la_SOURCES))

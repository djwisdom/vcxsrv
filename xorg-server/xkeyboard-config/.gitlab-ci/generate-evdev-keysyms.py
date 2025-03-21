#!/usr/bin/env python3
#
# Usage: generate-evdev-keysyms.py --template .gitlab-ci/inet.in > symbols/inet
#
# Generate the symbols/inet file from the names defined in
# linux/input-event-codes.h
#
# Note that this script relies on libevdev to provide the key names and
# those are compiled in. Ensure you have a recent-enough libevdev to
# generate this list.
#

import argparse
import contextlib
import re
import sys

# The marker to search for in the template file, replaced with our generated
# codes.
replacement_marker = "@evdevsyms@"

# These markers are put into the result file and are used to detect
# the section that we added when parsing an existing file.
section_header = "Key symbol mappings below are autogenerated"
section_footer = "End of autogenerated key symbol mappings"


def existing_keysyms(template):
    """
    Return an iterator of type (keycode, [keysym, keysym]) with the strings
    representing the internal keycode (e.g. I123) and the assigned keysyms.

    Only the "evdev" xkb_symbols section is parsed.
    """
    start_pattern = re.compile(r"xkb_symbols \"evdev\" {")
    end_pattern = re.compile(r"^};")

    # This does not handle multiline keysyms
    keysym_pattern = re.compile(
        r"\s+key \<(?P<keycode>\w+)\>\s+{\s+\[(?P<keysyms>[^]]+)\s*\]\s*};"
    )

    in_evdev = False

    template.seek(0)
    for line in template.readlines():
        if re.match(start_pattern, line):
            in_evdev = True
            continue
        if in_evdev:
            if re.match(end_pattern, line):
                break
            match = re.match(keysym_pattern, line)
            if match:
                keycode = match.group("keycode")
                keysyms = [k.strip() for k in match.group("keysyms").split(",")]
                yield keycode, keysyms


def xorgproto_evdev_keysyms(header):
    """
    Return an iterator of type ('XF86Foo', xkeycode, kernelname) for the keysyms in the
    given header file (usually XF86keysym.h).

    The returned xkeycode is the X keycode value (i.e. kernel value + 8)
    """

    # The two allowed formats in the proto header are:
    # #define XF86XK_FooBar _EVDEVK(0x123) ... KEY_FOOBAR
    # /* Use: XF86XK_FooBar _EVDEVK(0x123) ... KEY_FOOBAR
    # The keysym may not start with XF86XK_ (e.g. "dollar" or "euro")
    pattern = re.compile(
        r"(#define|/\* Use:)\s(?P<keyname>\w+)\s+_EVDEVK\(0x(?P<keycode>[0-9A-Fa-f]+)\).*(?P<kernelname>KEY_\w+)"
    )
    for line in header:
        match = re.match(pattern, line)
        if match:
            kernelname = match.group("kernelname")
            keyname = match.group("keyname").replace("XK_", "")
            keycode = int(match.group("keycode"), 16)
            xkeycode = keycode + 8
            yield keyname, xkeycode, kernelname


def generate_symbols_file(template, header):
    """
    Generate a new symbols/inet file with line containing @evdevsyms@
    replaced by the full list of evdev keysym mappings, including our
    section_header/footer. Expected output: ::

        // $section_header
           key <I$keycode> {      [ XF86Foo       ]       }; // KEY_FOO
        // key <I$keycode> { if assignment already exists }; // KEY_FOO
        ...
        // $section_footer

    Assignments that already exist in the file are commented out.
    """

    # We only care about the I123-style keysyms here
    keysyms = {
        int(kc[1:])
        for kc, _ in existing_keysyms(template)
        if re.match(r"I[0-9]{3}", kc)
    }

    output = []
    template.seek(0)
    for line in template.readlines():
        if replacement_marker not in line:
            output.append(line)
            continue

        output.append(f"   // {section_header}\n")
        for name, xkeycode, kernelname in xorgproto_evdev_keysyms(header):
            if xkeycode in keysyms:
                prefix = "//"
            else:
                prefix = "  "
            output.append(
                f"{prefix} key <I{xkeycode}>   {{       [ {name:30s} ]      }}; // {kernelname}\n"
            )
        output.append(f"  // {section_footer}\n")

    return output


def main():
    parser = argparse.ArgumentParser(description="Generate the evdev symbol lists.")
    parser.add_argument(
        "--template",
        type=argparse.FileType("r"),
        default=".gitlab-ci/inet.in",
        help="The template file, usually .gitlab-ci/inet.in",
    )
    parser.add_argument(
        "--header",
        type=argparse.FileType("r"),
        help="Path to the XF86keysym.h header file",
        default="/usr/include/X11/XF86keysym.h",
    )
    parser.add_argument(
        "--output",
        type=str,
        help="The file to be written to, usually symbols/inet",
        default="symbols/inet",
    )
    ns = parser.parse_args()

    with contextlib.ExitStack() as stack:
        if ns.output == "-":
            fd = sys.stdout
        else:
            fd = stack.enter_context(open(ns.output, "w"))
        output = generate_symbols_file(ns.template, ns.header)
        fd.write("".join(output))


if __name__ == "__main__":
    main()

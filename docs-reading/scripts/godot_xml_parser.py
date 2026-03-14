"""
godot_xml_parser.py

Parses Godot's native XML class reference files (doc/classes/*.xml)
directly into agent-optimised chunks.

Each XML file documents one class with this schema:

  <class name="CharacterBody2D" inherits="PhysicsBody2D" ...>
    <brief_description>...</brief_description>
    <description>...</description>
    <tutorials> <link ...>Title</link> </tutorials>
    <methods>
      <method name="move_and_slide">
        <return type="bool" />
        <param index="0" name="..." type="..." default="..." />
        <description>...</description>
      </method>
    </methods>
    <members>
      <member name="velocity" type="Vector2" setter="..." getter="..." default="...">
        Description text.
      </member>
    </members>
    <signals>
      <signal name="body_entered">
        <param index="0" name="body" type="Node2D" />
        <description>...</description>
      </signal>
    </signals>
    <constants>
      <constant name="MOTION_MODE_GROUNDED" value="0" enum="MotionMode">
        Description.
      </constant>
    </constants>
    <theme_items> ... </theme_items>
  </class>

Chunking strategy for agents:
  - One chunk per METHOD  (full signature + description + params)
  - One chunk per MEMBER property (name, type, default, description)
  - One chunk per SIGNAL
  - One chunk per ENUM group (all constants sharing an enum= attribute)
  - One chunk for class overview (brief + description + inheritance + tutorials)

This produces maximally precise retrieval: an agent asking about
move_and_slide() gets exactly that method's chunk, not the entire class.

BBCode ([b], [code], [param], [method], [member], [signal], [enum],
[constant], [url]) is stripped/converted to plain text for embeddings
and preserved in a readable form for the content field.
"""

import xml.etree.ElementTree as ET
import re
from pathlib import Path
from typing import Optional


# ── BBCode → readable text ────────────────────────────────────────────────────

_BBCODE_SIMPLE = re.compile(
    r"\[/?(?:b|i|u|s|indent|center|right|color(?:=[^\]]+)?|bgcolor(?:=[^\]]+)?|"
    r"fgcolor(?:=[^\]]+)?|url(?:=[^\]]+)?|img(?:[^\]]+)?|table|cell|row)\]",
    re.IGNORECASE,
)
_BBCODE_REF = re.compile(r"\[(?:method|member|signal|enum|constant|constructor|operator|annotation)\s+([^\]]+)\]")
_BBCODE_PARAM = re.compile(r"\[param\s+([^\]]+)\]")
_BBCODE_TYPE = re.compile(r"\[([A-Z][A-Za-z0-9_]*)\]")  # [Vector2], [Node], etc.
_BBCODE_CODE = re.compile(r"\[code\](.*?)\[/code\]", re.DOTALL)
_BBCODE_CODEBLOCK = re.compile(r"\[codeblock[^\]]*\](.*?)\[/codeblock\]", re.DOTALL)
_BBCODE_GDSCRIPT = re.compile(r"\[gdscript\](.*?)\[/gdscript\]", re.DOTALL)
_BBCODE_CSHARP = re.compile(r"\[csharp\](.*?)\[/csharp\]", re.DOTALL)


def bbcode_to_text(text: str, keep_code: bool = True) -> str:
    """
    Convert Godot BBCode to clean readable text.
    Code blocks are preserved as ```gdscript ... ``` by default.
    """
    if not text:
        return ""

    # Code blocks first (preserve content)
    if keep_code:
        text = _BBCODE_CODEBLOCK.sub(lambda m: f"\n```gdscript\n{m.group(1).strip()}\n```\n", text)
        text = _BBCODE_GDSCRIPT.sub(lambda m: f"\n```gdscript\n{m.group(1).strip()}\n```\n", text)
        text = _BBCODE_CSHARP.sub("", text)  # drop C# duplicates
        text = _BBCODE_CODE.sub(lambda m: f"`{m.group(1)}`", text)
    else:
        text = _BBCODE_CODEBLOCK.sub(lambda m: m.group(1).strip(), text)
        text = _BBCODE_GDSCRIPT.sub(lambda m: m.group(1).strip(), text)
        text = _BBCODE_CSHARP.sub("", text)
        text = _BBCODE_CODE.sub(lambda m: m.group(1), text)

    # Cross-references → readable
    text = _BBCODE_REF.sub(lambda m: m.group(1), text)
    text = _BBCODE_PARAM.sub(lambda m: m.group(1), text)
    text = _BBCODE_TYPE.sub(lambda m: m.group(1), text)

    # Strip remaining tags
    text = _BBCODE_SIMPLE.sub("", text)
    text = re.sub(r"\[/?[a-zA-Z_][^\]]*\]", "", text)  # catch-all

    # Clean whitespace
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def bbcode_to_plain(text: str) -> str:
    """Strip ALL BBCode including code blocks for embedding/FTS."""
    result = bbcode_to_text(text, keep_code=False)
    result = re.sub(r"```[^\n]*\n", "", result)
    result = re.sub(r"```", "", result)
    result = re.sub(r"`([^`]+)`", r"\1", result)
    return result.strip()


# ── Type signature helpers ────────────────────────────────────────────────────

def _type_str(type_name: str, enum: Optional[str] = None) -> str:
    if enum:
        return enum
    return type_name or "void"


def _format_param(param_el: ET.Element) -> str:
    name = param_el.get("name", "")
    type_ = _type_str(param_el.get("type", ""), param_el.get("enum"))
    default = param_el.get("default")
    if default is not None:
        return f"{type_} {name} = {default}"
    return f"{type_} {name}"


def _method_signature(method_el: ET.Element) -> str:
    """Build a GDScript-style method signature string."""
    name = method_el.get("name", "")
    is_static = method_el.get("is_static") == "true"
    is_const = method_el.get("is_const") == "true"
    qualifiers = method_el.get("qualifiers", "")

    return_el = method_el.find("return")
    return_type = _type_str(
        return_el.get("type", "void") if return_el is not None else "void",
        return_el.get("enum") if return_el is not None else None,
    )

    params = method_el.findall("param")
    param_str = ", ".join(_format_param(p) for p in sorted(params, key=lambda p: int(p.get("index", 0))))

    sig = f"func {name}({param_str}) -> {return_type}"
    if is_static:
        sig = "static " + sig
    if is_const or "const" in qualifiers:
        sig += "  # const"
    return sig


# ── Chunk factories ───────────────────────────────────────────────────────────

def _approx_tokens(text: str) -> int:
    return int(len(text.split()) * 1.3)


def _make_chunk(
    source_file: str,
    class_name: str,
    section: str,
    member_name: str,
    content: str,
    extra_plain: str = "",
) -> dict:
    heading_path = f"{class_name} > {section}" if member_name == section else f"{class_name} > {section} > {member_name}"
    anchor = f"#{section.lower().replace(' ', '-')}-{member_name.lower().replace('_', '-')}"
    plain = bbcode_to_plain(content) + (" " + extra_plain if extra_plain else "")
    return {
        "source_file": source_file,
        "heading_path": heading_path,
        "heading_level": 2 if member_name == section else 3,
        "section_anchor": anchor,
        "content": content,
        "content_plain": plain,
        "token_count": _approx_tokens(plain),
        "embedding": None,
    }


# ── Class XML → chunks ────────────────────────────────────────────────────────

def parse_class_xml(xml_path: Path) -> list[dict]:
    """
    Parse a single Godot class XML file into a list of chunk dicts.
    Returns [] on parse error.
    """
    try:
        tree = ET.parse(str(xml_path))
    except ET.ParseError as e:
        return []

    root = tree.getroot()
    if root.tag != "class":
        return []

    class_name = root.get("name", xml_path.stem)
    inherits = root.get("inherits", "")
    version = root.get("version", "")
    source_file = xml_path.name  # e.g. "CharacterBody2D.xml"

    chunks = []

    # ── 1. Class overview chunk ───────────────────────────────────────────────
    brief_el = root.find("brief_description")
    desc_el = root.find("description")
    tutorials_el = root.find("tutorials")

    brief = bbcode_to_text(brief_el.text or "" if brief_el is not None else "")
    desc = bbcode_to_text(desc_el.text or "" if desc_el is not None else "")

    tutorial_lines = []
    if tutorials_el is not None:
        for link in tutorials_el.findall("link"):
            title = (link.text or "").strip()
            url = link.get("href", "")
            if url:
                tutorial_lines.append(f"- [{title}]({url})" if title else f"- {url}")

    # Collect member/method/signal/constant counts for overview
    methods = root.findall(".//methods/method")
    members = root.findall(".//members/member")
    signals = root.findall(".//signals/signal")
    constants = root.findall(".//constants/constant")

    overview_parts = [f"# {class_name}"]
    if inherits:
        overview_parts.append(f"**Inherits:** {inherits}")
    if version:
        overview_parts.append(f"**Version:** {version}")
    overview_parts.append("")
    if brief:
        overview_parts.append(brief)
    if desc:
        overview_parts.append("")
        overview_parts.append(desc)
    if tutorial_lines:
        overview_parts.append("")
        overview_parts.append("**Tutorials:**")
        overview_parts.extend(tutorial_lines)

    # Quick API index for the overview chunk — helps agents know what exists
    if methods:
        overview_parts.append("")
        overview_parts.append(f"**Methods ({len(methods)}):** " +
            ", ".join(f"`{m.get('name', '')}`" for m in methods[:30]) +
            (" ..." if len(methods) > 30 else ""))
    if members:
        overview_parts.append(f"**Properties ({len(members)}):** " +
            ", ".join(f"`{m.get('name', '')}`" for m in members[:30]) +
            (" ..." if len(members) > 30 else ""))
    if signals:
        overview_parts.append(f"**Signals ({len(signals)}):** " +
            ", ".join(f"`{s.get('name', '')}`" for s in signals))
    if constants:
        # Group by enum
        enums = {}
        standalone = []
        for c in constants:
            enum = c.get("enum")
            if enum:
                enums.setdefault(enum, []).append(c.get("name", ""))
            else:
                standalone.append(c.get("name", ""))
        if enums:
            overview_parts.append(f"**Enums:** " + ", ".join(enums.keys()))
        if standalone:
            overview_parts.append(f"**Constants ({len(standalone)}):** " +
                ", ".join(f"`{n}`" for n in standalone[:20]))

    overview_content = "\n".join(overview_parts)
    overview_plain = bbcode_to_plain(overview_content)

    chunks.append({
        "source_file": source_file,
        "heading_path": class_name,
        "heading_level": 1,
        "section_anchor": f"#{class_name.lower()}",
        "content": overview_content,
        "content_plain": overview_plain,
        "token_count": _approx_tokens(overview_plain),
        "embedding": None,
    })

    # ── 2. Method chunks ──────────────────────────────────────────────────────
    methods_el = root.find("methods")
    if methods_el is not None:
        for method_el in methods_el.findall("method"):
            method_name = method_el.get("name", "")
            signature = _method_signature(method_el)
            desc_el2 = method_el.find("description")
            desc_text = bbcode_to_text(desc_el2.text or "" if desc_el2 is not None else "")

            # Param docs
            params = sorted(method_el.findall("param"), key=lambda p: int(p.get("index", 0)))
            param_docs = []
            for p in params:
                pname = p.get("name", "")
                ptype = _type_str(p.get("type", ""), p.get("enum"))
                pdefault = p.get("default")
                doc = f"- `{pname}` ({ptype})"
                if pdefault is not None:
                    doc += f" = `{pdefault}`"
                param_docs.append(doc)

            return_el = method_el.find("return")
            return_type = ""
            if return_el is not None:
                return_type = _type_str(return_el.get("type", "void"), return_el.get("enum"))

            content_parts = [
                f"## {class_name}.{method_name}()",
                "",
                f"```gdscript",
                signature,
                f"```",
                "",
            ]
            if desc_text:
                content_parts.append(desc_text)
                content_parts.append("")
            if param_docs:
                content_parts.append("**Parameters:**")
                content_parts.extend(param_docs)
                content_parts.append("")
            if return_type and return_type != "void":
                content_parts.append(f"**Returns:** `{return_type}`")

            content = "\n".join(content_parts).strip()
            # Extra plain text includes param names for FTS
            extra = " ".join(p.get("name", "") for p in params)
            chunks.append(_make_chunk(source_file, class_name, "Methods", method_name, content, extra))

    # ── 3. Member/property chunks ─────────────────────────────────────────────
    members_el = root.find("members")
    if members_el is not None:
        for member_el in members_el.findall("member"):
            mname = member_el.get("name", "")
            mtype = _type_str(member_el.get("type", ""), member_el.get("enum"))
            default = member_el.get("default")
            setter = member_el.get("setter", "")
            getter = member_el.get("getter", "")
            desc_text = bbcode_to_text(member_el.text or "")

            content_parts = [
                f"## {class_name}.{mname}",
                "",
                f"```gdscript",
                f"var {mname}: {mtype}" + (f" = {default}" if default is not None else ""),
                f"```",
                "",
            ]
            if desc_text:
                content_parts.append(desc_text)
                content_parts.append("")
            if setter:
                content_parts.append(f"**Setter:** `{setter}(value)`")
            if getter:
                content_parts.append(f"**Getter:** `{getter}()`")

            content = "\n".join(content_parts).strip()
            chunks.append(_make_chunk(source_file, class_name, "Properties", mname, content))

    # ── 4. Signal chunks ──────────────────────────────────────────────────────
    signals_el = root.find("signals")
    if signals_el is not None:
        for signal_el in signals_el.findall("signal"):
            sname = signal_el.get("name", "")
            params = sorted(signal_el.findall("param"), key=lambda p: int(p.get("index", 0)))
            param_str = ", ".join(_format_param(p) for p in params)
            desc_el3 = signal_el.find("description")
            desc_text = bbcode_to_text(desc_el3.text or "" if desc_el3 is not None else "")

            content_parts = [
                f"## {class_name} signal {sname}",
                "",
                f"```gdscript",
                f"signal {sname}({param_str})",
                f"```",
                "",
            ]
            if desc_text:
                content_parts.append(desc_text)

            content = "\n".join(content_parts).strip()
            chunks.append(_make_chunk(source_file, class_name, "Signals", sname, content))

    # ── 5. Enum/constant chunks (grouped by enum) ─────────────────────────────
    constants_el = root.find("constants")
    if constants_el is not None:
        # Group constants by their enum attribute
        enum_groups: dict[str, list[ET.Element]] = {}
        standalone_constants: list[ET.Element] = []

        for const_el in constants_el.findall("constant"):
            enum_name = const_el.get("enum")
            if enum_name:
                enum_groups.setdefault(enum_name, []).append(const_el)
            else:
                standalone_constants.append(const_el)

        # One chunk per enum group
        for enum_name, consts in enum_groups.items():
            content_parts = [f"## {class_name} enum {enum_name}", ""]
            for c in consts:
                cname = c.get("name", "")
                cval = c.get("value", "")
                cdesc = bbcode_to_plain(c.text or "").strip()
                line = f"- `{cname}` = `{cval}`"
                if cdesc:
                    line += f" — {cdesc}"
                content_parts.append(line)

            content = "\n".join(content_parts).strip()
            # plain: all constant names + descriptions
            plain_parts = [enum_name]
            for c in consts:
                plain_parts.append(c.get("name", ""))
                plain_parts.append(bbcode_to_plain(c.text or ""))
            chunks.append({
                "source_file": source_file,
                "heading_path": f"{class_name} > Enums > {enum_name}",
                "heading_level": 3,
                "section_anchor": f"#enum-{enum_name.lower()}",
                "content": content,
                "content_plain": " ".join(plain_parts),
                "token_count": _approx_tokens(" ".join(plain_parts)),
                "embedding": None,
            })

        # Standalone constants: batch into one chunk per class (usually small)
        if standalone_constants:
            content_parts = [f"## {class_name} Constants", ""]
            for c in standalone_constants:
                cname = c.get("name", "")
                cval = c.get("value", "")
                cdesc = bbcode_to_plain(c.text or "").strip()
                line = f"- `{cname}` = `{cval}`"
                if cdesc:
                    line += f" — {cdesc}"
                content_parts.append(line)
            content = "\n".join(content_parts).strip()
            plain = " ".join(
                c.get("name", "") + " " + bbcode_to_plain(c.text or "")
                for c in standalone_constants
            )
            chunks.append({
                "source_file": source_file,
                "heading_path": f"{class_name} > Constants",
                "heading_level": 2,
                "section_anchor": "#constants",
                "content": content,
                "content_plain": plain,
                "token_count": _approx_tokens(plain),
                "embedding": None,
            })

    return chunks

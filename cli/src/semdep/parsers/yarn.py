"""
Parsers for yarn.lock versions 1 and 2/3
Version 1 parser based on
https://www.arahansen.com/the-ultimate-guide-to-yarn-lock-lockfiles/
https://classic.yarnpkg.com/lang/en/docs/yarn-lock/

Version 2/3 parser based on looking at examples on github, I could not find any documentation
Here are the Yarn 2/3 docs: https://yarnpkg.com/
"""
from pathlib import Path
from typing import List
from typing import Optional
from typing import Set
from typing import Tuple
from typing import TypeVar

from semdep.external.parsy import any_char
from semdep.external.parsy import Parser
from semdep.external.parsy import peek
from semdep.external.parsy import regex
from semdep.external.parsy import string
from semdep.external.parsy import success
from semdep.parsers.util import consume_line
from semdep.parsers.util import extract_npm_lockfile_hash
from semdep.parsers.util import json_doc
from semdep.parsers.util import mark_line
from semdep.parsers.util import pair
from semdep.parsers.util import ParserName
from semdep.parsers.util import quoted
from semdep.parsers.util import safe_path_parse
from semdep.parsers.util import transitivity
from semdep.parsers.util import upto
from semgrep.semgrep_interfaces.semgrep_output_v1 import Ecosystem
from semgrep.semgrep_interfaces.semgrep_output_v1 import FoundDependency
from semgrep.semgrep_interfaces.semgrep_output_v1 import Npm
from semgrep.verbose_logging import getLogger

logger = getLogger(__name__)

A = TypeVar("A")

# The initial line of a yarn version 1 dependency, lists the constraints that lead to this package
# Examples:
# "@ampproject/remapping@^2.0.0"
# bad-lib@0.0.8
# "filedep@file:../../correct/path/filedep":
# "bats@https://github.com/bats-core/bats-core#master":
def source1(quoted: bool) -> "Parser[Tuple[str,str]]":

    return pair(
        string("@").optional("") + upto("@", consume_other=True),
        # If the source is quoted, then we know it ends at a quote
        # If it's not, then it must end at either a colon, or a comma
        # The colon is the end of the line (see the yarn_dep1 example)
        # The comma indicates we have a list of sources (see the multi_source1 example)
        upto(*(['"'] + ([":", ","] if not quoted else []))),
    )


# Examples:
# "@ampproject/remapping@^2.0.0", "@ampproject/remapping@^3.1.0"
# bad-lib@0.0.8, bad-lib@^0.0.4
multi_source1 = (quoted(source1(True)) | source1(False)).sep_by(string(", "))


# A key value pair. These can be a name followed by a nested list, but the only data we care about is in outermost list
# This is why we produce None if the line is preceeded by more than 2 spaces, or if it ends in a colon
# Examples:
#   version "2.1.1"
#   integrity sha512-Aolwjd7HSC2PyY0fDj/wA/EimQT4HfEnFYNp5s9CQlrdhyvWTtvZ5YzrUPu6R6/1jKiUlxu8bUhkdSnKHNAHMA==
#   dependencies:
key_value1: "Parser[Optional[Tuple[str,str]]]" = (
    string(" ")
    .many()
    .bind(
        lambda spaces: consume_line
        if len(spaces) != 2
        else upto(" ", ":").bind(
            lambda key: peek(any_char).bind(
                lambda next: consume_line
                if next == ":"
                else string(" ")
                >> upto("\n").bind(lambda value: success((key, value.strip('"'))))  # type: ignore
                # mypy seemingly cannot figure out that this function returns an optional
            )
        )
    )
)

# A full spec of a dependency
# Examples:
# "@ampproject/remapping@^2.0.0":
#   version "2.1.1"
#   resolved "https://registry.npmjs.org/@ampproject/remapping/-/remapping-2.1.1.tgz"
#   integrity sha512-Aolwjd7HSC2PyY0fDj/wA/EimQT4HfEnFYNp5s9CQlrdhyvWTtvZ5YzrUPu6R6/1jKiUlxu8bUhkdSnKHNAHMA==
#   dependencies:
#     "@jridgewell/trace-mapping" "^0.3.0"
yarn_dep1 = mark_line(
    pair(
        multi_source1 << string(":\n"),
        key_value1.sep_by(string("\n")).map(lambda xs: {x[0]: x[1] for x in xs if x}),
    )
)

YARN1_PREFIX = """\
# THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.
# yarn lockfile v1

"""

yarn1 = (
    string(YARN1_PREFIX)
    >> string("\n").optional()
    >> yarn_dep1.sep_by(string("\n\n"))
    << string("\n").optional()
)


# The yarn version 2/3 parser is set up equivalently, with slight differences in sub-parsers


def remove_npm_prefix(s: str) -> str:
    if s.startswith("npm:"):
        return s[4:]
    else:
        return s


# Examples:
# @ampproject/remapping@npm:^2.0.0
# @my-scope/my-first-package@my-scope/my-first-package#commit=0b824c650d3a03444dbcf2b27a5f3566f6e41358
# my-third-package@https://github.com/my-org/my-third-package#everything
# my-package@file:../../deps/my-local-package::locator=my-project%40workspace%3A.
# resolve@patch:resolve@^1.1.7#~builtin<compat/resolve>
source2 = pair(
    string("@").optional("") + upto("@", consume_other=True),
    # We remove the "npm:" prefix, because in a package.json, the version constraint will appear without it
    # e.g. "^1.0.0" in package.json becomes "npm:^1.0.0" in yarn.lock
    # However, prefix like "file:" *do* appear in package.json, so they aren't removed
    upto('"', ",").map(remove_npm_prefix),
)

# Examples:
# "@apidevtools/json-schema-ref-parser@npm:9.0.9"
# "@babel/generator@npm:^7.12.11, @babel/generator@npm:^7.12.5, @babel/generator@npm:^7.18.10"
multi_source2 = quoted(source2.sep_by(string(", ")))

# Examples:
#   version: 7.18.10
#   resolution: "@babel/generator@npm:7.18.10"
#   dependencies:
key_value2: "Parser[Optional[Tuple[str,str]]]" = (
    string(" ")
    .many()
    .bind(
        lambda spaces: consume_line
        if len(spaces) != 2
        else upto(":").bind(
            lambda key: string(":")
            >> peek(any_char).bind(
                lambda next: success(None)
                if next == "\n"
                else string(" ")
                >> upto("\n").bind(lambda value: success((key, value.strip('"'))))  # type: ignore
                # mypy seemingly cannot figure out that this function returns an optional
            )
        )
    )
)

# Examples:
# "@babel/generator@npm:^7.17.0, @babel/generator@npm:^7.7.2":
#   version: 7.17.0
#   resolution: "@babel/generator@npm:7.17.0"
#   dependencies:
#     "@babel/types": ^7.17.0
#     jsesc: ^2.5.1
#     source-map: ^0.5.0
#   checksum: 2987dbebb484727a227f1ce3db90810320986cfb3ffd23e6d1d87f75bbd8e7871b5bc44252822d4d5f048a2d872a5702b2a9bf7bab7e07f087d7f306f0ea6c0a
#   languageName: node
#   linkType: hard
yarn_dep2 = mark_line(
    pair(
        multi_source2 << string(":\n"),
        key_value2.sep_by(string("\n")).map(lambda xs: {x[0]: x[1] for x in xs if x}),
    )
)

YARN2_PREFIX = """\
# This file is generated by running "yarn install" inside your project.
# Manual changes might be lost - proceed with caution!
"""
YARN2_METADATA_REGEX = """\

__metadata:
  version: \\d+
  cacheKey: \\d+
"""
yarn2 = (
    string(YARN2_PREFIX)
    >> regex(YARN2_METADATA_REGEX).optional()
    >> string("\n").optional()
    >> yarn_dep2.sep_by(string("\n\n"))
    << string("\n").optional()
)


def get_manifest_deps(manifest_path: Optional[Path]) -> Optional[Set[Tuple[str, str]]]:
    """
    Extract a set of constraints from a package.json file
    """
    if not manifest_path:
        return None
    json_opt = safe_path_parse(manifest_path, json_doc, ParserName("jsondoc"))
    if not json_opt:
        return None
    json = json_opt.as_dict()
    deps = json.get("dependencies")
    if not deps:
        return set()
    return {(x[0], x[1].as_str()) for x in deps.as_dict().items()}


def remove_trailing_octothorpe(s: Optional[str]) -> Optional[str]:
    if s is None:
        return None
    else:
        return "#".join(s.split("#")[:-1]) if "#" in s else s


def parse_yarn(
    lockfile_path: Path, manifest_path: Optional[Path]
) -> List[FoundDependency]:
    with open(lockfile_path) as f:
        lockfile_text = f.read()
    manifest_deps = get_manifest_deps(manifest_path)
    yarn_version = 1 if lockfile_text.startswith(YARN1_PREFIX) else 2
    parser = yarn1 if yarn_version == 1 else yarn2
    parser_name = ParserName("yarn1") if yarn_version == 1 else ParserName("yarn2")
    deps = safe_path_parse(lockfile_path, parser, parser_name)
    if not deps:
        return []
    output = []
    for line_number, (sources, fields) in deps:
        if len(sources) < 1:
            continue
        if "version" not in fields:
            continue
        if yarn_version == 1:
            allowed_hashes = extract_npm_lockfile_hash(fields.get("integrity"))
        else:
            checksum = fields.get("checksum")
            allowed_hashes = {"sha512": [checksum]} if checksum else {}
        resolved_url = fields.get("resolved")
        output.append(
            FoundDependency(
                package=sources[0][0],
                version=fields["version"],
                ecosystem=Ecosystem(Npm()),
                allowed_hashes=allowed_hashes,
                resolved_url=remove_trailing_octothorpe(resolved_url),
                transitivity=transitivity(manifest_deps, sources),
                line_number=line_number,
            )
        )
    return output

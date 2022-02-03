import semgrep.constants as constants
import semgrep.rule_lang as rule_lang
import semgrep.semgrep_types as semgrep_types
from typing import Any, Dict, List, Optional, Sequence

class Rule:
    def __init__(self, raw: rule_lang.YamlTree[rule_lang.YamlMap]) -> None:
        ...

    @property
    def id(self) -> str:
        ...
    @property
    def message(self) -> str:
        ...
    @property
    def metadata(self) -> Dict[str, Any]:
        ...
    @property
    def severity(self) -> constants.RuleSeverity:
        ...
    @property
    def mode(self) -> str:
        ...

    @property
    def fix(self) -> Optional[str]:
        ...
    @property
    def fix_regex(self) -> Optional[Dict[str, Any]]:
        ...

    @property
    def project_depends_on(self) -> Optional[List[List[Dict[str, str]]]]:
        """
        If the rule contains `project-depends-on` keys under patterns, return the values of those keys
        Otherwise return None
        """
        ...

    @property
    def raw(self) -> Dict[str, Any]:
        ...

    @classmethod
    def from_json(cls, rule_json: Dict[str, Any]) -> Rule:
        ...
    @classmethod
    def from_yamltree(cls, rule_yaml: rule_lang.YamlTree[rule_lang.YamlMap]) -> Rule:
        ...

    def rename_id(self, new_id: str) -> None:
        ...

    @property
    def full_hash(self) -> str:
        """
        sha256 hash of the whole rule object instead of just the id
        """
        ...

    @property
    def should_run_on_semgrep_core(self) -> bool:
        """
        Used to detect whether the rule had patterns that need to run on the core
        (beyond Python-handled patterns, like `pattern-depends-on`).
        Remove this code once all rule runnning is done in the core and the answer is always 'yes'
        """
        ...

#TODO: this seems dead and not used outside the class
#    def __eq__(self, other: object) -> bool: ...
#    def __hash__(self) -> int: ...
#    @property
#    def includes(self) -> Sequence[str]: ...
#    @property
#    def excludes(self) -> Sequence[str]: ...
#    @property
#    def languages(self) -> List[semgrep_types.Language]: ...
#    @property
#    def languages_span(self) -> rule_lang.Span: ...

def rule_without_metadata(rule: Rule) -> Rule:
    ...

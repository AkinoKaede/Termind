from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "check_localization", Path(__file__).resolve().parents[1] / "check-cjk-localization.py"
)
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def catalog(key: str, value: str, state: str = "translated") -> dict:
    return {
        "sourceLanguage": "en",
        "strings": {key: {"localizations": {"ja": {"stringUnit": {"state": state, "value": value}}}}},
    }


def japanese_problems(data):
    return CHECK.problems(data, languages=("ja",))


class JapaneseLocalizationTests(unittest.TestCase):
    def test_rejects_spaces_in_both_directions_for_all_japanese_scripts(self):
        for value in ["日本語 API", "API 日本語", "ひらがな SSH", "SSH ひらがな", "サーバ API", "API サーバ",
                      "サーバ\tSSH", "SSH\u00a0サーバ", "サーバ\u3000SSH", "3 台", "サーバ 3"]:
            with self.subTest(value=value):
                self.assertTrue(any("spacing" in p for p in japanese_problems(catalog("Label", value))))

    def test_retains_english_protocol_spaces_and_japanese_label_spacing(self):
        for key, value in [("Label", "ssh user@hostで接続"), ("Label", "種類 不明"), ("Label", "SSHサーバ"),
                           ("Type %@", "種類 %@"), ("Type %@", "種類 %1$@")]:
            with self.subTest(value=value):
                self.assertEqual(japanese_problems(catalog(key, value)), [])

    def test_type_exception_is_narrow(self):
        self.assertTrue(japanese_problems(catalog("Label %@", "種類 %@")))
        self.assertTrue(japanese_problems(catalog("Type %@", "種類  %@")))
        self.assertTrue(japanese_problems(catalog("Type %@", "種類 %@の SSH鍵")))

    def test_reordered_arguments_keep_their_original_types(self):
        self.assertEqual(japanese_problems(catalog("%lld on %@", "%2$@で%1$lld件")), [])
        self.assertTrue(japanese_problems(catalog("%lld on %@", "%1$@で%2$lld件")))
        self.assertTrue(japanese_problems(catalog("%lld on %@", "%@で%lld件")))

    def test_rejects_lost_arguments_and_literal_percent(self):
        self.assertTrue(japanese_problems(catalog("%lld%% complete", "%lld完了")))
        self.assertTrue(japanese_problems(catalog("Host %@", "ホスト")))
        self.assertEqual(japanese_problems(catalog("%lld%% complete", "%lld%%完了")), [])

    def test_uses_localized_english_value_for_metadata_keys(self):
        data = catalog("NSCameraUsageDescription", "カメラを使用します。")
        data["strings"]["NSCameraUsageDescription"]["localizations"]["en"] = {
            "stringUnit": {"state": "translated", "value": "Use the camera."}
        }
        self.assertEqual(japanese_problems(data), [])

    def test_rejects_missing_unfinished_and_empty_translations(self):
        data = catalog("Settings", "設定")
        data["strings"]["Settings"]["localizations"] = {}
        self.assertTrue(japanese_problems(data))
        self.assertTrue(japanese_problems(catalog("Settings", "設定", "needs_review")))
        self.assertTrue(japanese_problems(catalog("Settings", "")))
        self.assertEqual(japanese_problems(catalog("", "")), [])

    def test_checks_plural_units_and_rejects_non_japanese_categories(self):
        data = catalog("%lld files", "%lld個のファイル")
        localizations = data["strings"]["%lld files"]["localizations"]
        unit = localizations["ja"]
        localizations["en"] = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
            "other": {"stringUnit": {"state": "translated", "value": "%lld files"}},
        }}}
        self.assertTrue(japanese_problems(data))
        localizations["ja"] = {"variations": {"plural": {"other": unit}}}
        self.assertEqual(japanese_problems(data), [])
        unit["stringUnit"]["value"] = "%lld ファイル"
        self.assertTrue(japanese_problems(data))
        unit["stringUnit"]["value"] = "%lld個のファイル"
        localizations["ja"]["variations"]["plural"]["one"] = unit
        self.assertTrue(japanese_problems(data))

    def test_respects_nontranslatable_entries(self):
        data = catalog("Identifier", "")
        data["strings"]["Identifier"]["shouldTranslate"] = False
        self.assertEqual(japanese_problems(data), [])


class ChineseLocalizationTests(unittest.TestCase):
    def check(self, key, value, language):
        data = catalog(key, value)
        localizations = data["strings"][key]["localizations"]
        localizations[language] = localizations.pop("ja")
        return CHECK.problems(data, languages=(language,))

    def test_preserves_chinese_spacing_and_punctuation_checks(self):
        for language in ["zh-Hans", "zh-Hant"]:
            for value in ["中文 SSH", "SSH 中文", "中文,", "中文： SSH", "SSH ：中文"]:
                with self.subTest(language=language, value=value):
                    self.assertTrue(self.check("Label", value, language))
            self.assertEqual(self.check("Label", "中文SSH", language), [])

    def test_preserves_type_subtitle_exception(self):
        for language, label in [("zh-Hans", "类型"), ("zh-Hant", "類型")]:
            self.assertEqual(self.check("Type %@", label + " %@", language), [])
            self.assertTrue(self.check("Other %@", label + " %@", language))

    def test_shared_validation_requires_every_supported_language(self):
        data = catalog("Settings", "設定")
        failures = CHECK.problems(data)
        self.assertEqual(len(failures), 2)
        self.assertTrue(any("zh-Hans" in failure for failure in failures))
        self.assertTrue(any("zh-Hant" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()

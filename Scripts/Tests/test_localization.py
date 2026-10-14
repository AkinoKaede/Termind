from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "check_localization", Path(__file__).resolve().parents[1] / "check-localization.py"
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
        self.assertEqual(len(failures), len(CHECK.SUPPORTED_LANGUAGES) - 1)
        self.assertTrue(any("zh-Hans" in failure for failure in failures))
        self.assertTrue(any("zh-Hant" in failure for failure in failures))


class KoreanLocalizationTests(unittest.TestCase):
    def make_catalog(self, key, value):
        data = catalog(key, value)
        localizations = data["strings"][key]["localizations"]
        localizations["ko"] = localizations.pop("ja")
        return data

    def test_allows_korean_word_spacing_and_protocol_names(self):
        for value in ["SSH 인증 실패", "파일 3개", "사용자 확인 요청 안 함", "암호 구문"]:
            with self.subTest(value=value):
                self.assertEqual(CHECK.problems(self.make_catalog("Label", value), languages=("ko",)), [])

    def test_reordered_arguments_preserve_positions_and_types(self):
        data = self.make_catalog("Command failed with exit code %lld after %@.",
                                 "명령이 %2$@ 후 종료 코드 %1$lld로 실패했습니다.")
        self.assertEqual(CHECK.problems(data, languages=("ko",)), [])
        unit = data["strings"]["Command failed with exit code %lld after %@."]["localizations"]["ko"]["stringUnit"]
        unit["value"] = "명령이 %@ 후 종료 코드 %lld로 실패했습니다."
        self.assertTrue(any("format arguments" in p for p in CHECK.problems(data, languages=("ko",))))

    def test_requires_only_other_for_counted_resources(self):
        data = self.make_catalog("%lld files", "파일 %lld개")
        localizations = data["strings"]["%lld files"]["localizations"]
        unit = localizations["ko"]
        localizations["en"] = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
            "other": {"stringUnit": {"state": "translated", "value": "%lld files"}},
        }}}
        self.assertTrue(CHECK.problems(data, languages=("ko",)))
        localizations["ko"] = {"variations": {"plural": {"other": unit}}}
        self.assertEqual(CHECK.problems(data, languages=("ko",)), [])
        localizations["ko"]["variations"]["plural"]["one"] = unit
        self.assertTrue(CHECK.problems(data, languages=("ko",)))

    def test_rejects_missing_and_unfinished_korean(self):
        data = self.make_catalog("Settings", "설정")
        unit = data["strings"]["Settings"]["localizations"]["ko"]["stringUnit"]
        unit["state"] = "needs_review"
        self.assertEqual(CHECK.problems(data, languages=("ko",)), ["'Settings': unfinished ko translation"])
        del data["strings"]["Settings"]["localizations"]["ko"]
        self.assertEqual(CHECK.problems(data, languages=("ko",)), ["'Settings': missing ko translation"])


class EuropeanLocalizationTests(unittest.TestCase):
    def make_catalog(self, key, value, language):
        return {
            "sourceLanguage": "en",
            "strings": {key: {"localizations": {
                language: {"stringUnit": {"state": "translated", "value": value}},
            }}},
        }

    def test_checks_coverage_state_and_positional_arguments(self):
        for language in ("de", "fr"):
            with self.subTest(language=language):
                data = self.make_catalog("%lld on %@", "%2$@ : %1$lld", language)
                self.assertEqual(CHECK.problems(data, languages=(language,)), [])
                unit = data["strings"]["%lld on %@"]["localizations"][language]["stringUnit"]
                unit["value"] = "%1$@ : %2$lld"
                self.assertTrue(CHECK.problems(data, languages=(language,)))
                unit["value"] = "%lld on %@"
                unit["state"] = "needs_review"
                self.assertTrue(CHECK.problems(data, languages=(language,)))
                del data["strings"]["%lld on %@"]["localizations"][language]
                self.assertTrue(CHECK.problems(data, languages=(language,)))

    def test_requires_singular_and_plural_even_for_target_only_variations(self):
        for language in ("de", "fr"):
            data = self.make_catalog("%lld files", "%lld fichiers", language)
            localizations = data["strings"]["%lld files"]["localizations"]
            unit = localizations[language]
            localizations[language] = {"variations": {"plural": {"other": unit}}}
            self.assertTrue(CHECK.problems(data, languages=(language,)))
            forms = localizations[language]["variations"]["plural"]
            forms["one"] = unit
            self.assertEqual(CHECK.problems(data, languages=(language,)), [])
            forms["few"] = unit
            self.assertTrue(CHECK.problems(data, languages=(language,)))
            del forms["few"]
            forms["many"] = unit
            failures = CHECK.problems(data, languages=(language,))
            self.assertEqual(bool(failures), language == "de")

    def test_english_plural_requires_translated_plural_variations(self):
        for language in ("de", "fr"):
            data = self.make_catalog("%lld files", "%lld fichiers", language)
            localizations = data["strings"]["%lld files"]["localizations"]
            localizations["en"] = {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld files"}},
            }}}
            self.assertTrue(CHECK.problems(data, languages=(language,)))

    def test_each_plural_branch_preserves_format_arguments(self):
        data = self.make_catalog("%lld files", "%lld fichiers", "fr")
        localizations = data["strings"]["%lld files"]["localizations"]
        localizations["fr"] = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "un fichier"}},
            "other": localizations["fr"],
        }}}
        self.assertTrue(any("format arguments" in p for p in CHECK.problems(data, languages=("fr",))))

    def test_preserves_european_typography_without_cjk_spacing_rules(self):
        for language, value in [("fr", "Échec\u00a0: «\u00a0clé SSH\u00a0»\u202f?"), ("de", "Schlüssel „SSH“")]:
            data = self.make_catalog("Label", value, language)
            self.assertEqual(CHECK.problems(data, languages=(language,)), [])

    def test_explicit_scope_can_limit_checks_to_german_and_french(self):
        data = self.make_catalog("Settings", "Einstellungen", "de")
        self.assertEqual(CHECK.problems(data, languages=("de", "fr")), ["'Settings': missing fr translation"])
        data["strings"]["Settings"]["localizations"]["fr"] = {
            "stringUnit": {"state": "translated", "value": "Réglages"}
        }
        self.assertEqual(CHECK.problems(data, languages=("de", "fr")), [])

    def test_uses_english_metadata_value_and_skips_nontranslatable_entries(self):
        data = self.make_catalog("BundleKey", "Datei %@", "de")
        data["strings"]["BundleKey"]["localizations"]["en"] = {
            "stringUnit": {"state": "translated", "value": "File %@"}
        }
        self.assertEqual(CHECK.problems(data, languages=("de",)), [])
        data["strings"]["Identifier"] = {"shouldTranslate": False}
        self.assertEqual(CHECK.problems(data, languages=("de",)), [])


if __name__ == "__main__":
    unittest.main()

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from release_tools import current_tag, next_tag, order_problem, previous_release, render_item, upsert_items


def item(version, build="1"):
    return render_item(version, build=build, min_os="15.0", enclosure_url=f"https://x/{version}.dmg",
                       sig_attrs='sparkle:edSignature="s" length="1"')


class NextTagTests(unittest.TestCase):
    def test_patch_minor_major_bump_from_the_latest_release(self):
        tags = ["v0.9.3", "v0.9.4"]
        self.assertEqual(next_tag("patch", tags), "v0.9.5")
        self.assertEqual(next_tag("minor", tags), "v0.10.0")
        self.assertEqual(next_tag("major", tags), "v1.0.0")

    def test_promoting_a_beta_bumps_from_the_latest_release_not_the_beta(self):
        tags = ["v0.9.4", "v0.10.0-beta.1", "v0.10.0-beta.2"]
        self.assertEqual(next_tag("minor", tags), "v0.10.0")

    def test_beta_continues_the_beta_in_progress(self):
        tags = ["v0.9.4", "v0.10.0-beta.1", "v0.10.0-beta.2"]
        self.assertEqual(next_tag("beta", tags), "v0.10.0-beta.3")

    def test_beta_compares_beta_numbers_numerically(self):
        tags = ["v0.9.4", "v0.10.0-beta.9", "v0.10.0-beta.10"]
        self.assertEqual(next_tag("beta", tags), "v0.10.0-beta.11")

    def test_beta_without_one_in_progress_asks_for_an_explicit_start(self):
        with self.assertRaisesRegex(ValueError, r"v0\.11\.0-beta\.1"):
            next_tag("beta", ["v0.9.4", "v0.10.0-beta.2", "v0.10.0"])

    def test_explicit_versions_are_accepted(self):
        self.assertEqual(next_tag("v0.10.0-beta.1", ["v0.9.4"]), "v0.10.0-beta.1")
        self.assertEqual(next_tag("v0.9.5", ["v0.9.4"]), "v0.9.5")

    def test_a_malformed_explicit_version_is_refused(self):
        for bad in ["v0.10", "0.10.0", "v0.10.0-rc.1", "v0.10.0-beta", "v0.10.0-beta.0", "nightly"]:
            with self.assertRaises(ValueError, msg=bad):
                next_tag(bad, ["v0.9.4"])

    def test_the_new_version_must_be_newer_than_every_existing_one(self):
        tags = ["v0.9.4", "v0.10.0-beta.2"]
        with self.assertRaisesRegex(ValueError, "newer"):
            next_tag("patch", tags)
        with self.assertRaisesRegex(ValueError, "newer"):
            next_tag("v0.10.0-beta.1", tags)
        with self.assertRaisesRegex(ValueError, "newer"):
            next_tag("v0.9.4-beta.1", ["v0.9.4"])

    def test_a_release_follows_its_own_betas(self):
        self.assertEqual(next_tag("v0.10.0", ["v0.9.4", "v0.10.0-beta.2"]), "v0.10.0")

    def test_tags_that_are_not_versions_are_ignored(self):
        self.assertEqual(next_tag("patch", ["v0.9.4", "before-agent-merge", "v0.9.x"]), "v0.9.5")

    def test_a_new_tag_never_shares_a_commit_with_an_existing_version(self):
        tags = ["v0.9.4", "v0.10.0-beta.3"]
        for bump in ["minor", "v0.10.0", "beta"]:
            with self.assertRaisesRegex(ValueError, r"v0\.10\.0-beta\.3", msg=bump):
                next_tag(bump, tags, tags_at_head=["v0.10.0-beta.3"])

    def test_tags_at_head_that_are_not_versions_do_not_block(self):
        self.assertEqual(next_tag("patch", ["v0.9.4"], tags_at_head=["backup"]), "v0.9.5")

    def test_a_relative_bump_needs_a_release_to_start_from(self):
        with self.assertRaisesRegex(ValueError, "explicit"):
            next_tag("patch", [])


class CurrentTagTests(unittest.TestCase):
    def test_a_release_cut_from_its_last_beta_reads_as_the_release(self):
        self.assertEqual(current_tag(["v0.10.0-beta.3", "v0.10.0"], "v0.10.0-beta.3"), "v0.10.0")

    def test_other_tags_at_head_are_ignored(self):
        self.assertEqual(current_tag(["backup", "v0.9.4"], "v0.9.4"), "v0.9.4")

    def test_without_a_version_tag_at_head_it_falls_back_to_the_nearest_one(self):
        self.assertEqual(current_tag([], "v0.9.4"), "v0.9.4")
        self.assertEqual(current_tag([], ""), "")


class PreviousReleaseTests(unittest.TestCase):
    def test_a_release_notes_from_the_release_before_it_not_its_betas(self):
        tags = ["v0.9.3", "v0.9.4", "v0.10.0-beta.1", "v0.10.0-beta.2", "v0.10.0"]
        self.assertEqual(previous_release("v0.10.0", tags), "v0.9.4")

    def test_a_beta_keeps_the_default_notes(self):
        self.assertIsNone(previous_release("v0.10.0-beta.2", ["v0.9.4", "v0.10.0-beta.1"]))

    def test_the_first_release_has_none(self):
        self.assertIsNone(previous_release("v0.1.0", ["v0.1.0"]))


class OrderTests(unittest.TestCase):
    def test_a_release_on_its_last_betas_build_is_refused(self):
        items = [item("0.10.0-beta.3", "450"), item("0.9.4", "352")]
        self.assertIn("0.10.0-beta.3", order_problem(items, "0.10.0", "450"))

    def test_a_hotfix_that_outgrew_a_betas_build_is_refused(self):
        items = [item("0.10.0-beta.1", "446"), item("0.9.4", "352")]
        self.assertIn("0.10.0-beta.1", order_problem(items, "0.9.5", "500"))

    def test_a_hotfix_below_the_beta_is_fine(self):
        items = [item("0.10.0-beta.1", "446"), item("0.9.4", "352")]
        self.assertIsNone(order_problem(items, "0.9.5", "353"))

    def test_republishing_the_same_version_is_fine(self):
        self.assertIsNone(order_problem([item("0.9.4", "352")], "0.9.4", "352"))

    def test_a_newer_version_with_an_older_build_is_refused(self):
        self.assertIn("0.9.4", order_problem([item("0.9.4", "352")], "0.9.5", "300"))


class AppcastTests(unittest.TestCase):
    def test_a_beta_item_is_posted_to_the_beta_channel(self):
        self.assertIn("<sparkle:channel>beta</sparkle:channel>", render_item(
            "0.10.0-beta.1", build="400", min_os="15.0", enclosure_url="u", sig_attrs="s"))

    def test_a_release_item_stays_in_the_default_channel(self):
        self.assertNotIn("sparkle:channel", render_item(
            "0.10.0", build="400", min_os="15.0", enclosure_url="u", sig_attrs="s"))

    def test_upsert_prepends_and_replaces_the_same_version(self):
        old = [item("0.9.4"), item("0.9.3")]
        fresh = item("0.9.4")
        self.assertEqual(upsert_items(old, fresh, "0.9.4", keep=10), [fresh, old[1]])

    def test_trimming_never_drops_the_newest_release(self):
        betas = [item(f"0.10.0-beta.{n}") for n in range(12, 2, -1)]
        old = betas + [item("0.9.4"), item("0.9.3")]
        result = upsert_items(old, item("0.10.0-beta.13"), "0.10.0-beta.13", keep=10)
        self.assertEqual(len(result), 11)
        self.assertEqual(result[-1], item("0.9.4"))
        self.assertNotIn(item("0.9.3"), result)

    def test_trimming_keeps_only_the_limit_when_a_release_is_inside_it(self):
        old = [item(f"0.9.{n}") for n in range(12, 0, -1)]
        result = upsert_items(old, item("0.9.13"), "0.9.13", keep=10)
        self.assertEqual(len(result), 10)


if __name__ == "__main__":
    unittest.main()

"""The release plan and update feed, without git, GitHub or a signing key."""
import base64
import importlib.util
import io
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_feed', REPO / 'Scripts/release_feed.py')
feed = importlib.util.module_from_spec(spec)
# dataclasses looks the module up by name while the classes are being built.
sys.modules['release_feed'] = feed
spec.loader.exec_module(feed)

SIGNATURE = base64.b64encode(bytes(64)).decode()
SPARKLE = '{' + feed.SPARKLE_NS + '}'


def item(build, channel='testing', **changes):
    base = feed.Item(build=build, version='3.6.0', channel=channel,
                     url=f'https://example.com/Stockbar-{build}.zip', length=10, signature=SIGNATURE,
                     minimum_system='15.4.0', published='Wed, 11 Nov 2026 12:00:00 +0000', notes='- A change')
    return replace(base, **changes)


class PlanTests(unittest.TestCase):
    def plan(self, ref_type='branch', ref_name='testing', describe='v3.6.0-14-gabc1234',
             version='3.6.0', build='360', newest_tag=''):
        return feed.plan(ref_type, ref_name, describe, version, build, newest_tag)

    def test_a_push_to_testing_is_numbered_after_the_release_it_follows(self):
        plan = self.plan()
        self.assertEqual((plan.mode, plan.channel, plan.build, plan.version),
                         ('publish', 'testing', '360.14', '3.6.0'))
        self.assertEqual((plan.release_tag, plan.asset_name), ('testing-360.14', 'Stockbar-360.14.zip'))

    def test_a_testing_build_keeps_the_old_base_until_the_new_version_is_tagged(self):
        # release.sh has moved the project to 3.7.0, but v3.7.0 does not exist yet.
        plan = self.plan(version='3.7.0', build='370')
        self.assertEqual((plan.build, plan.version), ('360.14', '3.7.0'))

    def test_the_tagged_commit_itself_is_not_published_as_a_testing_build(self):
        plan = self.plan(describe='v3.6.0-0-gabc1234')
        self.assertEqual(plan.mode, 'skip')
        self.assertIn('v3.6.0', plan.reason)

    def test_a_testing_build_that_would_sort_below_the_newest_release_is_refused(self):
        # v3.7.0 was tagged on a commit that testing does not contain.
        with self.assertRaisesRegex(feed.ReleaseError, 'v3.7.0 is not in the history of testing'):
            self.plan(newest_tag='v3.7.0')
        self.assertEqual(self.plan(newest_tag='v3.6.0').build, '360.14')
        self.assertEqual(self.plan(newest_tag='v3.5.0').build, '360.14')
        # A dry run publishes nothing, so an old branch may still be built.
        self.assertEqual(self.plan(ref_name='release-test/old', newest_tag='v3.7.0').mode, 'dry-run')

    def test_any_other_branch_is_a_dry_run(self):
        self.assertEqual(self.plan(ref_name='release-test/first').mode, 'dry-run')
        self.assertEqual(self.plan(ref_name='release-test/first', describe='v3.6.0-0-gabc1234').build, '360.0')

    def test_a_version_tag_is_a_stable_release(self):
        plan = self.plan(ref_type='tag', ref_name='v3.6.0', describe='')
        self.assertEqual((plan.mode, plan.channel, plan.build, plan.version, plan.release_tag, plan.asset_name),
                         ('publish', 'stable', '360', '3.6.0', 'v3.6.0', 'Stockbar-3.6.0.zip'))

    def test_a_tag_that_disagrees_with_the_project_is_refused(self):
        with self.assertRaisesRegex(feed.ReleaseError, 'release.sh'):
            self.plan(ref_type='tag', ref_name='v3.7.0', describe='')

    def test_tags_the_build_number_cannot_express_are_refused(self):
        for tag in ('v3.10.0', 'v3.6', 'testing-360.14', '3.6.0'):
            with self.subTest(tag=tag), self.assertRaises(feed.ReleaseError):
                self.plan(ref_type='tag', ref_name=tag, describe='')

    def test_a_branch_with_no_reachable_version_tag_is_refused(self):
        for describe in ('', 'fatal: No names found', 'testing-360.2-3-gabc1234'):
            with self.subTest(describe=describe), self.assertRaises(feed.ReleaseError):
                self.plan(describe=describe)

    def test_the_project_must_state_one_version(self):
        text = 'MARKETING_VERSION = 3.6.0;\nCURRENT_PROJECT_VERSION = 360;\nMARKETING_VERSION = 3.6.0;\n'
        self.assertEqual(feed.project_setting(text, 'MARKETING_VERSION'), '3.6.0')
        self.assertEqual(feed.project_setting(text, 'CURRENT_PROJECT_VERSION'), '360')
        with self.assertRaises(feed.ReleaseError):
            feed.project_setting(text + 'MARKETING_VERSION = 3.7.0;\n', 'MARKETING_VERSION')
        with self.assertRaises(feed.ReleaseError):
            feed.project_setting('', 'MARKETING_VERSION')

    def test_the_real_project_states_one_version(self):
        text = (REPO / 'Stockbar.xcodeproj/project.pbxproj').read_text()
        version = feed.project_setting(text, 'MARKETING_VERSION')
        self.assertEqual(feed.stable_build('v' + version), feed.project_setting(text, 'CURRENT_PROJECT_VERSION'))


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stockbar-feed-')
        self.path = Path(self.temp.name) / 'appcast.xml'

    def tearDown(self):
        self.temp.cleanup()

    def write(self, items):
        self.path.write_text(feed.render_feed(items, 'https://example.com/repo'), encoding='utf-8')

    def test_builds_sort_the_way_the_updater_compares_them(self):
        builds = ['370.2', '360', '360.14', '370', '360.2']
        self.assertEqual(sorted(builds, key=feed.build_key), ['360', '360.2', '360.14', '370', '370.2'])

    def test_a_feed_survives_being_written_and_read_back(self):
        items = [item('360.2', notes='Fixed <b> & "quotes" ]]> done\n\n- second line', link='https://example.com/r'),
                 item('360', channel='stable')]
        self.write(items)
        self.assertEqual(feed.read_feed(self.path), items)

    def test_only_testing_builds_carry_a_channel(self):
        self.write([item('360.2'), item('360', channel='stable')])
        elements = ET.parse(self.path).getroot().findall('channel/item')
        self.assertEqual([element.findtext(SPARKLE + 'channel') for element in elements], ['testing', None])
        self.assertEqual(elements[0].find('description').get(SPARKLE + 'format'), 'markdown')
        self.assertEqual(elements[0].find('enclosure').get(SPARKLE + 'edSignature'), SIGNATURE)

    def test_a_missing_feed_is_empty_and_a_broken_one_is_never_replaced(self):
        self.assertEqual(feed.read_feed(self.path), [])
        self.path.write_text('<rss><channel><item>')
        with self.assertRaisesRegex(feed.ReleaseError, 'Refusing'):
            feed.read_feed(self.path)
        self.path.write_text('<rss><channel><item><title>x</title></item></channel></rss>')
        with self.assertRaisesRegex(feed.ReleaseError, 'Refusing'):
            feed.read_feed(self.path)
        self.path.write_text('<!DOCTYPE rss [<!ENTITY a "aaaa">]><rss><channel/></rss>')
        with self.assertRaisesRegex(feed.ReleaseError, 'document type'):
            feed.read_feed(self.path)

    def test_the_old_signature_is_dropped_when_the_feed_is_rewritten(self):
        self.write([item('360.1')])
        with self.path.open('a') as handle:
            handle.write('<!-- sparkle-signatures:\nedSignature: abc\nlength: 1\n-->\n')
        rewritten = feed.render_feed(feed.add(feed.read_feed(self.path), item('360.2')), 'https://example.com/repo')
        self.assertNotIn('sparkle-signatures', rewritten)
        self.assertEqual(rewritten.count('<item>'), 2)

    def test_adding_puts_the_newest_build_first_and_replaces_a_rebuilt_one(self):
        items = feed.add([item('360.1'), item('360.3')], item('360.2'))
        self.assertEqual([entry.build for entry in items], ['360.3', '360.2', '360.1'])
        items = feed.add(items, item('360.2', length=99))
        self.assertEqual([(entry.build, entry.length) for entry in items],
                         [('360.3', 10), ('360.2', 99), ('360.1', 10)])

    def test_only_the_newest_builds_are_kept(self):
        items = [item(f'360.{number}') for number in range(1, 15)]
        items += [item(str(number), channel='stable') for number in (300, 310, 320, 330)]
        kept = feed.prune(items)
        self.assertEqual([entry.build for entry in kept if entry.channel == 'testing'],
                         [f'360.{number}' for number in range(14, 4, -1)])
        self.assertEqual([entry.build for entry in kept if entry.channel == 'stable'], ['330', '320', '310'])

    def test_a_release_retires_the_testing_builds_before_it(self):
        items = feed.add([item('360.1'), item('360.2'), item('360', channel='stable')],
                         item('370', channel='stable', version='3.7.0'))
        self.assertEqual([entry.build for entry in items], ['370', '360'])
        items = feed.add(items, item('370.1', version='3.7.0'))
        self.assertEqual([entry.build for entry in items], ['370.1', '370', '360'])

    def test_bad_entries_are_refused(self):
        bad = [
            item('360.1', channel='beta'),
            item('3.6.0-beta'),
            item('360.1', version=' '),
            item('360.1', url='http://example.com/Stockbar.zip'),
            item('360.1', length=0),
            item('360.1', signature='not base64!'),
            item('360.1', signature=base64.b64encode(bytes(32)).decode()),
        ]
        for entry in bad:
            with self.subTest(entry=entry), self.assertRaises(feed.ReleaseError):
                feed.add([], entry)
        # A feed served from this Mac, for the local update test.
        feed.add([], item('360.1', url='http://127.0.0.1:8123/Stockbar-360.1.zip'))

    def test_the_minimum_system_is_written_in_three_parts(self):
        self.assertEqual([feed.three_part(version) for version in ('15', '15.4', '15.4.1')],
                         ['15.0.0', '15.4.0', '15.4.1'])
        for version in ('', '15.x', '15.4.1.2'):
            with self.subTest(version=version), self.assertRaises(feed.ReleaseError):
                feed.three_part(version)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='stockbar-feed-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = feed._main([str(arg) for arg in args])
        return status, out.getvalue(), err.getvalue()

    def add(self, build, channel, notes='- A change\n'):
        notes_file = self.root / 'notes.md'
        notes_file.write_text(notes)
        return self.run_command('add', '--appcast', self.root / 'appcast.xml', '--channel', channel,
                                '--build', build, '--version', '3.6.0',
                                '--url', f'https://example.com/Stockbar-{build}.zip', '--length', 10,
                                '--signature', SIGNATURE, '--minimum-system', '15.4', '--notes-file', notes_file)

    def test_plan_prints_the_values_the_workflow_reads(self):
        project = self.root / 'project.pbxproj'
        project.write_text('MARKETING_VERSION = 3.6.0;\nCURRENT_PROJECT_VERSION = 360;\n')
        status, out, _ = self.run_command('plan', '--ref-type', 'branch', '--ref-name', 'testing',
                                          '--describe', 'v3.6.0-2-gabc1234', '--project', project)
        self.assertEqual(status, 0)
        self.assertEqual(dict(line.split('=', 1) for line in out.splitlines()), {
            'mode': 'publish', 'channel': 'testing', 'build': '360.2', 'version': '3.6.0',
            'release_tag': 'testing-360.2', 'asset_name': 'Stockbar-360.2.zip', 'reason': ''})

    def test_a_refused_plan_explains_itself_and_fails(self):
        project = self.root / 'project.pbxproj'
        project.write_text('MARKETING_VERSION = 3.6.0;\nCURRENT_PROJECT_VERSION = 360;\n')
        status, out, err = self.run_command('plan', '--ref-type', 'tag', '--ref-name', 'v3.7.0',
                                            '--project', project)
        self.assertEqual((status, out), (1, ''))
        self.assertIn('v3.7.0', err)

    def test_add_then_builds_lists_each_channel(self):
        self.assertEqual(self.add('360', 'stable')[0], 0)
        self.assertEqual(self.add('360.1', 'testing')[0], 0)
        self.assertEqual(self.add('360.2', 'testing', notes='')[0], 0)
        appcast = self.root / 'appcast.xml'
        self.assertEqual(self.run_command('builds', '--appcast', appcast, '--channel', 'testing')[1],
                         '360.2\n360.1\n')
        self.assertEqual(self.run_command('builds', '--appcast', appcast, '--channel', 'stable')[1], '360\n')
        newest = feed.read_feed(appcast)[0]
        self.assertEqual((newest.notes, newest.minimum_system), ('No release notes.', '15.4.0'))

    def test_a_refused_entry_leaves_the_feed_as_it_was(self):
        self.add('360.1', 'testing')
        before = (self.root / 'appcast.xml').read_text()
        status, _, err = self.add('not-a-build', 'testing')
        self.assertEqual(status, 1)
        self.assertIn('build number', err)
        self.assertEqual((self.root / 'appcast.xml').read_text(), before)


if __name__ == '__main__':
    unittest.main()

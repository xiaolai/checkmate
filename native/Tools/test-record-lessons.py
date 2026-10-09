"""Offline recorder contracts: no network, credentials or playback."""
import importlib.util
import io
import json
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recorder', HERE / 'record-lessons.py')
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


def wav(samples=b'\x00\x10'):
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(24000)
        audio.writeframes(samples * 24000)
    return buffer.getvalue()


class RecordingTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((HERE.parent / 'Content/narration-profile.cedar.json').read_text())
        self.unit = recorder.load_units(HERE.parent / 'Content/lesson-narration.en-GB.jsonl')[0]
        self.body = recorder.payload(self.profile, self.unit['text'])

    def testCompletionVerifierRejectsMissingAndCorruptAssets(self):
        spec=importlib.util.spec_from_file_location('verifier',HERE / 'verify-lesson-recordings.py')
        verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)
            verified,missing,failures=verifier.verify(self.profile,[self.unit],output)
            self.assertEqual(missing,[self.unit['id']])
            metadata,_=recorder.record(self.unit,self.body,self.profile,output,lambda _: (wav(),'test'))
            verified,missing,failures=verifier.verify(self.profile,[self.unit],output)
            self.assertEqual(len(verified),1)
            self.assertEqual((missing,failures),([],[]))
            (output / metadata['file']).write_bytes(b'corrupt')
            verified,missing,failures=verifier.verify(self.profile,[self.unit],output)
            self.assertEqual(len(failures),1)
            self.assertEqual(verified,[])

    def testEveryProviderSettingInvalidatesCache(self):
        original = recorder.request_hash(self.body)
        for field, value in [('model', 'new-model'), ('voice', 'marin'), ('input', 'Changed text'),
                             ('instructions', 'Different delivery'), ('speed', 0.95), ('response_format', 'mp3')]:
            self.assertNotEqual(original, recorder.request_hash(dict(self.body, **{field: value})))

    def testParallelBatchRetainsManifestOrderAndCachesAllTakes(self):
        units=recorder.load_units(HERE.parent / 'Content/lesson-narration.en-GB.jsonl')[:8]
        bodies=[recorder.payload(self.profile, unit['text']) for unit in units]
        with tempfile.TemporaryDirectory() as directory:
            render=unittest.mock.Mock(return_value=(wav(), 'test-request'))
            results=recorder.record_batch(units,bodies,self.profile,Path(directory),render,4,lambda *_:None)
            self.assertEqual([r['id'] for r in results],[u['id'] for u in units])
            self.assertEqual(render.call_count,8)
            recorder.record_batch(units,bodies,self.profile,Path(directory),render,4,lambda *_:None)
            self.assertEqual(render.call_count,8)

    def testBadSpeedAndOversizedTextFailBeforeNetwork(self):
        for speed in [float('nan'), float('inf'), 0, 5]:
            with self.assertRaises(ValueError):
                recorder.payload(self.profile, 'Hello', speed)
        with self.assertRaises(ValueError):
            recorder.payload(self.profile, 'a' * 4097)

    def testSuccessfulTakeIsReusedAndCorruptionNeverSilentlyPasses(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            render = unittest.mock.Mock(return_value=(wav(), 'test-request'))
            first, cached = recorder.record(self.unit, self.body, self.profile, output, render)
            self.assertFalse(cached)
            self.assertEqual(first['audio']['seconds'], 1)
            second, cached = recorder.record(self.unit, self.body, self.profile, output, render)
            self.assertTrue(cached)
            self.assertEqual(first, second)
            self.assertEqual(render.call_count, 1)
            (output / first['file']).write_bytes(b'corrupt')
            with self.assertRaises(ValueError):
                recorder.record(self.unit, self.body, self.profile, output, render)
            self.assertEqual(render.call_count, 1)

    def testFailedGenerationDoesNotPublishARecording(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with self.assertRaises(ValueError):
                recorder.record(self.unit, self.body, self.profile, output,
                                unittest.mock.Mock(side_effect=ValueError('HTTP 401')))
            self.assertEqual(list(output.rglob('*.wav')), [])
            self.assertEqual(list(output.rglob('*.json')), [])

    def testIncompletePairRequiresInspectionWithoutSpending(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            metadata, _ = recorder.record(self.unit, self.body, self.profile, output, lambda _: (wav(), None))
            (output / metadata['file']).with_suffix('.json').unlink()
            render = unittest.mock.Mock()
            with self.assertRaises(ValueError):
                recorder.record(self.unit, self.body, self.profile, output, render)
            render.assert_not_called()

    def testSilentAndTruncatedAudioIsRejected(self):
        with self.assertRaises((ValueError, wave.Error, EOFError)):
            recorder.audio_info(wav()[:-10])
        silent = wav(b'\x00\x00')
        with self.assertRaises(ValueError):
            recorder.audio_info(silent)

    def testStreamingWavLengthUsesActualDecodedFrames(self):
        data=bytearray(wav())
        data[4:8]=b'\xff' * 4
        offset=data.index(b'data')+4
        data[offset:offset+4]=b'\xff' * 4
        self.assertEqual(recorder.audio_info(bytes(data))['seconds'],1)
        self.assertEqual(recorder.finalize_wav(bytes(data)),wav())

    def testAlteredInputHashIsRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.jsonl'
            path.write_text(json.dumps(dict(self.unit, text='Changed')))
            with self.assertRaises(ValueError):
                recorder.load_units(path)


if __name__ == '__main__':
    unittest.main()

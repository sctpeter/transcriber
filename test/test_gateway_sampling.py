#!/usr/bin/env python3
"""网关采样参数单测(不需要 llama-server):parse_sampling 校验 + build_chat_request
最终发给 llama-server 的字段类型。真实接口验证见 test/test_remote_sampling_live.sh。

用法: uv run --with websockets python test/test_gateway_sampling.py
"""
import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
from qwen3_asr_gateway import build_chat_request, parse_sampling  # noqa: E402

FULL = {"samplers": ["top_k", "top_p", "min_p", "temperature"],
        "temperature": 0.0, "top_k": 40, "top_p": 0.95, "min_p": 0.05}


def header(**sampling):
    return {"type": "segment", "id": 1, "sampling": {**FULL, **sampling}}


class ParseSampling(unittest.TestCase):
    def test_absent_means_server_default(self):
        self.assertIsNone(parse_sampling({"type": "segment", "id": 1}))

    def test_order_normalized(self):
        got = parse_sampling(header(samplers=["temperature", "min_p", "top_k"]))
        self.assertEqual(got["samplers"], ["top_k", "min_p", "temperature"])

    def test_rejects_unknown(self):
        with self.assertRaises(ValueError):
            parse_sampling(header(samplers=["top_k", "xtc", "temperature"]))

    def test_rejects_duplicate(self):
        with self.assertRaises(ValueError):
            parse_sampling(header(samplers=["top_k", "top_k", "temperature"]))

    def test_rejects_missing_temperature(self):
        with self.assertRaises(ValueError):
            parse_sampling(header(samplers=["top_k", "top_p"]))

    def test_rejects_empty_or_wrong_type(self):
        for bad in ([], "top_k;temperature", None):
            with self.assertRaises(ValueError):
                parse_sampling(header(samplers=bad))
        with self.assertRaises(ValueError):
            parse_sampling({"sampling": "top_k"})

    def test_rejects_out_of_range(self):
        for kw in ({"temperature": 2.5}, {"temperature": -0.1}, {"top_k": 201}, {"top_k": -1},
                   {"top_p": 1.1}, {"min_p": -0.01}, {"temperature": float("nan")}):
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                parse_sampling(header(**kw))

    def test_rejects_non_integer_top_k(self):
        for v in (20.7, True, "20"):
            with self.subTest(v=v), self.assertRaises(ValueError):
                parse_sampling(header(top_k=v))

    def test_rejects_missing_value(self):
        raw = dict(FULL)
        del raw["min_p"]
        with self.assertRaises(ValueError):
            parse_sampling({"sampling": raw})


class BuildChatRequest(unittest.TestCase):
    WAV = b"RIFF-fake-wav"

    def test_default_sends_no_sampling_fields(self):
        body = build_chat_request(self.WAV, "m", None)
        for key in ("samplers", "temperature", "top_k", "top_p", "min_p"):
            self.assertNotIn(key, body)
        content = body["messages"][0]["content"]
        self.assertEqual(content[0], {"type": "text", "text": "Transcribe audio to text"})
        self.assertEqual(base64.b64decode(content[1]["input_audio"]["data"]), self.WAV)

    def test_override_uses_json_numbers_and_only_selected(self):
        sampling = parse_sampling(header(samplers=["top_p", "temperature"], top_p=0.9, temperature=0.2))
        # 经过一次 JSON 序列化/反序列化,确认线上类型:数值不是字符串(b10991 multipart 的坑)
        body = json.loads(json.dumps(build_chat_request(self.WAV, "m", sampling)))
        self.assertEqual(body["samplers"], ["top_p", "temperature"])
        self.assertIsInstance(body["top_p"], float)
        self.assertIsInstance(body["temperature"], float)
        self.assertNotIn("top_k", body)
        self.assertNotIn("min_p", body)

    def test_top_k_is_json_integer(self):
        body = json.loads(json.dumps(build_chat_request(self.WAV, "m", parse_sampling(header(top_k=20)))))
        self.assertIs(type(body["top_k"]), int)


if __name__ == "__main__":
    unittest.main(verbosity=2)

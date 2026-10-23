"""Shared private-delivery wire contract; no network or model calls."""
import json
from pathlib import Path

REQUIRED_FILES = ('Chinese.ass', 'Bilingual.ass', 'Chinese.srt', 'Bilingual.srt',
                  'cues.json', 'quality.json', 'recognition-provenance.json',
                  'manifest.json', 'usage.json')
MAX_FILE_BYTES = 500_000
MAX_DELIVERY_BYTES = 2_000_000


def encode_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def compact_cues(rows):
    """Keep the existing list schema; raw word evidence stays in checkpoints."""
    return [{key: row[key] for key in ('id', 'start', 'end', 'text', 'zh', 'review') if key in row}
            for row in sorted(rows, key=lambda r: (r['start'], r['end'], r['id']))]


def preflight_delivery(rows):
    minimal = compact_cues([dict(row, zh='', review=False) for row in rows])
    cue_bytes = len(encode_json(minimal).encode('utf-8'))
    source_bytes = sum(len(row['text'].encode('utf-8')) for row in rows)
    if max(cue_bytes, source_bytes) > MAX_FILE_BYTES:
        raise ValueError('Delivery source alone exceeds file limit; no further model calls')
    return {'cue_json_lower_bound_bytes': cue_bytes, 'source_text_bytes': source_bytes,
            'max_file_bytes': MAX_FILE_BYTES, 'max_delivery_bytes': MAX_DELIVERY_BYTES,
            'final_size_guaranteed': False, 'raw_word_evidence_retained_in': 'primary-cues.json'}


def check_delivery(folder):
    total = 0
    for name in REQUIRED_FILES:
        path = Path(folder) / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
            raise ValueError('Delivery file missing or oversized: ' + name + '; checkpoints retained; do not rerun paid calls')
        total += path.stat().st_size
    if total > MAX_DELIVERY_BYTES:
        raise ValueError('Delivery total size exceeded; checkpoints retained; do not rerun paid calls')
    return total

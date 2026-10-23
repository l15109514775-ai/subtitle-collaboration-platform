"""Run every Python suite, including tests/, without external network access.

Linux: python run_offline_tests.py
Windows diagnostic only: python run_offline_tests.py --windows-adapter
The Windows adapter does not validate POSIX fsync/flock or production durability.
"""
import argparse
import importlib
import json
import os
from pathlib import Path
import socket
import subprocess
import re
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-adapter',action='store_true')
    parser.add_argument('--report',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parent
    os.chdir(root)
    adapter=sys.platform=='win32' and args.windows_adapter
    if sys.platform=='win32' and not adapter:
        parser.error('Use Linux for production acceptance, or explicitly select --windows-adapter')
    if adapter:
        sys.modules['fcntl']=types.SimpleNamespace(LOCK_EX=2,LOCK_UN=8,flock=lambda *a:None)
        import worker
        original=worker.save
        def portable_save(path,value):
            path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
            temporary=path.with_suffix(path.suffix+'.tmp')
            content=worker.encode_json(value) if path.name in ('cues.json','quality.json') and path.parent.name=='delivery' else json.dumps(value,ensure_ascii=False,indent=2)
            temporary.write_text(content,encoding='utf-8');temporary.replace(path)
        for name in ('worker','runtime','qwen_asr','qwen_recovery','clip_pipeline','clip_budget','clip_sources','clip_media'):
            module=importlib.import_module(name)
            if getattr(module,'save',None) is original:module.save=portable_save
    connect=socket.socket.connect
    def local_only(sock,address):
        if isinstance(address,tuple) and address[0] not in ('127.0.0.1','::1','localhost'):
            raise RuntimeError('Offline suite blocked external connection')
        return connect(sock,address)
    # Only synthetic credentials are visible to tests. No real provider request
    # is permitted; loopback HTTP redirect/fixture tests remain available.
    synthetic={name:'synthetic-offline-only' for name in ('SUBTITLE_GPT_TOKEN','SUBTITLE_QWEN_TOKEN','SUBTITLE_PLATFORM_TOKEN','SUBTITLE_PLATFORM_GATEWAY_KEY')}
    with patch.dict(os.environ,synthetic),patch.object(socket.socket,'connect',local_only):
        suite=unittest.defaultTestLoader.discover(str(root),pattern='test_*.py',top_level_dir=str(root))
        result=unittest.TextTestRunner(verbosity=2).run(suite)
    ui_file=root/'tests/test_operations_ui.cjs'
    ui={'required':ui_file.is_file(),'passed':None}
    if ui_file.is_file():
        try:
            completed=subprocess.run(['node','--test','--test-reporter=tap',str(ui_file)],capture_output=True,text=True,encoding='utf-8',timeout=60,env={**os.environ,**synthetic})
            print(completed.stdout);print(completed.stderr,file=sys.stderr)
            ui={'required':True,'passed':completed.returncode==0,'returncode':completed.returncode}
            for label in ('tests','pass','fail','skipped'):
                match=re.search(r'^# '+label+r' (\d+)$',completed.stdout,re.M)
                if match:ui[label]=int(match.group(1))
        except (OSError,subprocess.TimeoutExpired):
            ui={'required':True,'passed':False,'error':'Node UI suite could not run; do not silently skip'}
    overall=result.wasSuccessful() and (not ui['required'] or ui['passed'])
    report={'tests_run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),
            'skipped':[reason for test,reason in result.skipped], 'passed':bool(overall),'ui_tests':ui,
            'platform':sys.platform,'windows_persistence_adapter':adapter,'live_model_calls':False}
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False))
    return 0 if overall else 1


if __name__=='__main__':
    sys.exit(main())

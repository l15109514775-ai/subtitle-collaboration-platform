"""Fail publication on common credentials, private deployment IDs and bad links.
Prints paths/rules/line numbers only, never the matched secret.
"""
from pathlib import Path
import ast,json,re,os,sys
ROOT=Path(__file__).resolve().parents[1]
SKIP={'.git','node_modules','.venv','__pycache__','build','data','access','runtime'}
PATTERNS={
 'JWT':re.compile(r'eyJ[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+'),
 'private-key':re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
 'provider-secret':re.compile(r'(?<!\w)(?:sk[-_]|gh[pousr]_)[A-Za-z0-9_-]{24,}'),
 'cloud-secret-id':re.compile(r'\bAKID[A-Za-z0-9]{20,}\b'),
 'original-environment':re.compile('subtitledev-'+r'[a-z0-9]+'),
 'local-user-path':re.compile(r'(?i)[A-Z]:[/\\]+Users[/\\]+[^/\\\s]+'),
 'original-machine-path':re.compile(r'[A-Z]:[/\\]+CodexFiles[/\\]+(?:Apps|Chats)[/\\]'),
 'private-chat-link':re.compile(r'https://chatgpt.com/(?:local|c|share)/(?!00000000)[0-9a-f-]{30,}'),
}
TEXT={'.py','.js','.mjs','.cjs','.sql','.md','.txt','.json','.yaml','.yml','.html','.css','.svg','.sh','.cmd','.lock',''}
def files():
 for folder,dirs,names in os.walk(ROOT):
  dirs[:]=[d for d in dirs if d not in SKIP]
  for name in sorted(names):yield Path(folder)/name
def main():
 errors=[];count=0
 for p in files():
  rel=p.relative_to(ROOT).as_posix();count+=1
  if p.suffix.lower() in {'.mp4','.mkv','.webm','.mov','.wav','.mp3','.sqlite3','.db','.zip','.pem','.key','.pfx','.ass','.srt'}:errors.append((rel,'private/binary artifact',0));continue
  try:s=p.read_text(encoding='utf-8-sig')
  except UnicodeDecodeError:errors.append((rel,'unknown binary',0));continue
  for rule,pattern in PATTERNS.items():
   for m in pattern.finditer(s):errors.append((rel,rule,s.count('\n',0,m.start())+1))
  if p.suffix=='.py':
   try:ast.parse(s)
   except SyntaxError as e:errors.append((rel,'Python syntax',e.lineno))
  if p.suffix=='.json':
   try:json.loads(s)
   except ValueError:errors.append((rel,'JSON syntax',0))
  if p.suffix=='.md' and not rel.startswith(('experiments/','worker/')):
   for dest in re.findall(r'\]\(([^)]+)\)',s):
    if '://' in dest or dest.startswith(('#','mailto:')):continue
    dest=dest.split('#')[0]
    if dest and not (p.parent/dest).exists():errors.append((rel,'missing relative document link',0))
 if errors:
  for rel,rule,line in errors:print(f'FAIL {rel}:{line}: {rule}')
  print(f'{len(errors)} findings; no matching values printed');return 1
 print(f'PASS {count} source files: release content, common credential patterns, Python/JSON syntax and maintained document links')
 return 0
if __name__=='__main__':sys.exit(main())

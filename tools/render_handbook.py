"""Render local Chinese Markdown guides to offline HTML."""
from pathlib import Path
import re, html
R=Path(__file__).resolve().parents[1]
# A local Markdown renderer for the nontechnical reader; no third-party JS,
# CDN, telemetry or login. Main source remains the Markdown beside the HTML.
style='body{margin:0;background:#edf4fa;color:#183148;font:17px/1.8 system-ui,sans-serif}main{max-width:940px;margin:36px auto;padding:38px 46px;background:white;border-radius:18px}nav{font-size:15px;border-bottom:1px solid #d7e3ed;padding-bottom:18px}h1{font-size:34px;line-height:1.3}h2{margin-top:48px;color:#245c89}a{color:#166aaf}table{border-collapse:collapse;width:100%;display:block;overflow-x:auto}td,th{border:1px solid #d7e3ed;padding:10px 14px;text-align:left}th{background:#edf4fa}code,pre{background:#f0f4f8;border-radius:5px}code{padding:2px 5px}pre{padding:18px;overflow:auto;font-size:14px}blockquote{border-left:4px solid #5d9fcf;margin:18px 0;padding:8px 20px;background:#f3f8fc}li{margin:7px 0}@media(max-width:650px){main{margin:0;padding:24px 18px;border-radius:0}h1{font-size:28px}}'
(R/'docs/handbook.css').write_text(style,encoding='utf8')
def inline(s):
 s=html.escape(s)
 s=re.sub(r'`([^`]+)`',r'<code>\1</code>',s)
 s=re.sub(r'\*\*([^*]+)\*\*',r'<strong>\1</strong>',s)
 def link(m):
  dest=m.group(2)
  if dest.endswith('.md'):
   target=Path(dest)
   if not dest.startswith('../') and (R/'docs'/target).exists():dest=dest[:-3]+'.html'
  return '<a href="'+dest+'">'+m.group(1)+'</a>'
 return re.sub(r'\[([^\]]+)\]\(([^)]+)\)',link,s)
def render(s):
 out=[];table=False;ul=False;code=False;buf=[]
 for line in s.splitlines():
  if line.startswith('```'):
   if code:out.append('<pre><code>'+html.escape('\n'.join(buf))+'</code></pre>');buf=[]
   code=not code;continue
  if code:buf.append(line);continue
  if line.startswith('|'):
   if re.fullmatch(r'[| :\-]+',line):continue
   cells=line.strip('|').split('|')
   tag='td' if table else 'th'
   if not table:out.append('<table>');table=True
   out.append('<tr>'+''.join('<'+tag+'>'+inline(c.strip())+'</'+tag+'>' for c in cells)+'</tr>');continue
  if table:out.append('</table>');table=False
  islist=re.match(r'^(?:- |\d+\. )(.*)',line)
  if islist:
   if not ul:out.append('<ul>');ul=True
   out.append('<li>'+inline(line if line[0].isdigit() else islist[1])+'</li>');continue
  if ul:out.append('</ul>');ul=False
  if not line.strip():continue
  head=re.match(r'^(#{1,4}) (.+)',line)
  if head:out.append(f'<h{len(head[1])}>'+inline(head[2])+f'</h{len(head[1])}>')
  elif line.startswith('> '):out.append('<blockquote>'+inline(line[2:])+'</blockquote>')
  else:out.append('<p>'+inline(line)+'</p>')
 if table:out.append('</table>')
 if ul:out.append('</ul>')
 return '\n'.join(out)
for p in (R/'docs').glob('*.md'):
 content='<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+html.escape(p.stem)+' · 字幕协作台</title><link rel="stylesheet" href="handbook.css"></head><body><main><nav><a href="从零搭建.html">从零搭建</a> · <a href="使用手册.html">日常使用</a> · <a href="维护与排错.html">维护排错</a> · <a href="验证状态.html">验证状态</a></nav>'+render(p.read_text(encoding='utf8'))+'<hr><p>开源字幕协作台 · AGPL-3.0-only · 文档源文件与本页放在同一目录。</p></main></body></html>'
 p.with_suffix('.html').write_text(content,encoding='utf8')
print('Offline handbook rendered')

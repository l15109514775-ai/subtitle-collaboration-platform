"""Generate a separate deployment folder. Never connects to any service."""
from pathlib import Path
import argparse,json,re,shutil,zipfile
from urllib.parse import urlsplit

ROOT=Path(__file__).resolve().parents[1]
def sql_quote(value):return "'"+value.replace("'","''")+"'"
def validate(cfg):
 if not re.fullmatch(r'[a-z][a-z0-9-]{2,79}',cfg['environment_id']) or cfg['environment_id'] in ('your-environment-id','example-env'):raise ValueError('请填写自己的完整 CloudBase 环境 ID')
 for key in ('website_url','text_api_url'):
  u=urlsplit(cfg[key])
  if u.scheme!='https' or not u.hostname or u.username or u.password or u.port not in (None,443) or u.query or u.fragment or any(c in cfg[key] for c in "'\"<>\\\r\n\t "):raise ValueError(key+' 必须是完整 HTTPS 地址，不带密码、参数或引号')
  if (u.hostname.endswith(('.example','.invalid')) or u.hostname.startswith('your-')) and not (key=='text_api_url' and cfg[key]=='https://text-provider.example.invalid/v1'):raise ValueError('请替换 '+key+' 示例')
 if urlsplit(cfg['text_api_url']).path.rstrip('/')!='/v1':raise ValueError('文字服务须支持 /v1/responses；填写以 /v1 结尾的地址')
 if urlsplit(cfg['text_api_url']).hostname in ('api.openai.com','platform.openai.com'):raise ValueError('此版本保留原项目规则：官方 OpenAI 密钥不用于文字翻译；不要自动改用其他计费渠道')
 if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,99}',cfg['text_model']):raise ValueError('模型名只能包含英文、数字、点、横线和下划线')
 if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',cfg['cloud_environment_name']):raise ValueError('云环境名称使用英文、数字、点、横线和下划线')
 subject=cfg['owner_auth_subject']
 if subject=='COPY_YOUR_AUTH_USER_ID_HERE' or not re.fullmatch(r'[A-Za-z0-9._:@-]{1,200}',subject):raise ValueError('请复制自己在身份认证中的用户 ID，不是用户名/邮箱，也不是密码')
 return cfg
def render(cfg,out):
 validate(cfg)
 if out.exists():raise ValueError('输出目录已存在，请选择新目录；不会覆盖旧部署或凭据')
 out.mkdir(parents=True)
 replacements={
  'example-env.api.tcloudbasegateway.com':cfg['environment_id']+'.api.tcloudbasegateway.com',
  'example-site.tcloudbaseapp.com':urlsplit(cfg['website_url']).netloc,
  'subtitle-delivery-20min-active':cfg['cloud_environment_name'],
  'https://text-provider.example.invalid/v1':cfg['text_api_url'].rstrip('/'),
  'text-provider.example.invalid':urlsplit(cfg['text_api_url']).hostname,
  'gpt-6-luna':cfg['text_model'],
 }
 for folder in ['site','worker','bot','ops','database','tools']:
  for source in (ROOT/folder).rglob('*'):
   if not source.is_file() or any(x in {'.venv','__pycache__','node_modules'} for x in source.parts):continue
   if source.suffix in {'.pyc','.log','.sqlite3'}:continue
   target=out/source.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
   content=source.read_text(encoding='utf8')
   for a,b in replacements.items():content=content.replace(a,b)
   target.write_text(content,encoding='utf8',newline='\n')
 # One first-install transaction: a failed statement must not expose an
 # intermediate permission model. The file is intentionally not a live upgrade.
 parts=[]
 for name in json.loads((ROOT/'database/migrations.json').read_text(encoding='utf8')):
  text=(out/'database/migrations'/name).read_text(encoding='utf8')
  text=re.sub(r'^BEGIN;\s*$', '',text,flags=re.M)
  text=re.sub(r'^COMMIT;\s*$', '',text,flags=re.M)
  text=re.sub(r"^SET LOCAL (?:lock_timeout|statement_timeout)=.*?;\s*$",'',text,flags=re.M)
  parts.append('-- '+name+'\n'+text)
 preflight="""BEGIN;
SET LOCAL statement_timeout='180s';
DO $$ BEGIN
 IF to_regclass('public.st_members') IS NOT NULL THEN RAISE EXCEPTION 'Only install into an empty environment; existing business tables detected'; END IF;
 IF to_regclass('auth.users') IS NULL OR to_regclass('storage.objects') IS NULL OR to_regprocedure('auth.uid()') IS NULL THEN RAISE EXCEPTION 'CloudBase PostgreSQL auth/storage schemas required'; END IF;
END; $$;
"""
 (out/'database/INSTALL_ALL.sql').write_text(preflight+'\n'.join(parts)+'\nCOMMIT;\n',encoding='utf8')
 subject=sql_quote(cfg['owner_auth_subject'])
 owner=f"""-- In your OWN CloudBase SQL editor, after creating your own auth account.
BEGIN;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.st_member_roles WHERE role_code='owner') THEN RAISE EXCEPTION 'An owner already exists; do not silently add another'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')={subject}) THEN RAISE EXCEPTION 'Authentication user not found; verify the user ID'; END IF;
END; $$;
INSERT INTO public.st_members(auth_subject,display_name) VALUES({subject},'组长') ON CONFLICT(auth_subject) DO NOTHING;
INSERT INTO public.st_member_roles(member_id,role_code) SELECT id,'owner' FROM public.st_members WHERE auth_subject={subject};
COMMIT;
"""
 (out/'database/SET_FIRST_OWNER.sql').write_text(owner,encoding='utf8')
 (out/'README_FIRST.txt').write_text('部署文件只在本地生成，尚未上传或购买资源。按仓库 docs/从零搭建.md 操作。只上传 site/ 内文件到静态网站；不要上传整个目录。数据库文件只用于全新空环境。worker/ 是 Cloud 工作器；bot/ 是机器人插件。\n',encoding='utf8')
 with zipfile.ZipFile(out/'website-upload.zip','w',zipfile.ZIP_DEFLATED) as z:
  for p in (out/'site').rglob('*'):
   if p.is_file():z.write(p,p.relative_to(out/'site').as_posix())
 return out
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--config',type=Path)
 parser.add_argument('--out',type=Path,default=ROOT/'build/deployment')
 args=parser.parse_args()
 if args.config:cfg=json.loads(args.config.read_text(encoding='utf-8-sig'))
 else:
  print('字幕协作台部署准备：仅在本地生成文件，不联网、不收费，也不需要密码或密钥。')
  cfg={}
  for key,label in [('environment_id','腾讯云完整环境 ID'),('website_url','自己的静态网站 HTTPS 地址'),('cloud_environment_name','Codex Cloud 环境名 [回车使用 subtitle-delivery-20min-active]'),('text_api_url','已获授权的文字模型服务地址（以 /v1 结尾）'),('text_model','文字模型名 [回车使用 gpt-6-luna]'),('owner_auth_subject','组长在 CloudBase 身份认证中的用户 ID')]:cfg[key]=input(label+'：').strip()
  cfg['cloud_environment_name']=cfg['cloud_environment_name'] or 'subtitle-delivery-20min-active'
  cfg['text_model']=cfg['text_model'] or 'gpt-6-luna'
  cfg['text_api_url']=cfg['text_api_url'] or 'https://text-provider.example.invalid/v1'
 try:result=render(cfg,args.out.resolve())
 except (ValueError,KeyError,OSError) as e:raise SystemExit(str(e))
 print('已生成：'+str(result)+'。请从 docs/从零搭建.md 的发布步骤继续。')
if __name__=='__main__':main()

"""Run on the bot server, from the generated deployment package. No network."""
import argparse,base64,getpass,hashlib,json,os,re,secrets,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def quote(s):return "'"+s.replace("'","''")+"'"
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--deployment',type=Path,required=True);parser.add_argument('--data',type=Path,default=Path('/opt/subtitlebot/data'));args=parser.parse_args()
 data=args.data.resolve();source=args.deployment.resolve()
 target=data/'subtitle_bridge.json'
 plugins=['astrbot_plugin_subtitle_bridge','astrbot_plugin_subtitle_notify']
 protected=[target,data/'REGISTER_GATEWAY.sql',data/'subtitle_notifications.json']+[data/'plugins'/p for p in plugins]
 if any(p.exists() or p.is_symlink() for p in protected):raise SystemExit('已有机器人配置、绑定或插件，停止以避免覆盖。更新插件时使用维护文档。')
 if any(not (source/'bot/plugins'/p/'main.py').is_file() for p in plugins):raise SystemExit('部署包不完整，未写入任何配置。')
 if 'example-env' in (source/'bot/plugins/astrbot_plugin_subtitle_notify/main.py').read_text(encoding='utf8'):raise SystemExit('请先运行 configure.py 生成自己的部署文件。')
 app=input('QQ AppID（机器人开发设置中查看）：').strip()
 platform=input('AstrBot 平台实例 ID（复制完整值，常见为 default_加AppID）：').strip()
 subject=input('网站组长在身份认证中的用户 ID：').strip()
 if not re.fullmatch(r'[0-9]{5,30}',app) or not re.fullmatch(r'[A-Za-z0-9_-]{1,150}',platform) or not re.fullmatch(r'[A-Za-z0-9._:@-]{1,200}',subject):raise SystemExit('ID 格式不正确')
 publishable=getpass.getpass('CloudBase Publishable Key / anon（输入隐藏，不是 service_role）：').strip()
 try:
  payload=publishable.split('.')[1];claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
  if claims.get('role')!='anon':raise ValueError()
 except Exception:raise SystemExit('需要 role=anon 的 Publishable Key；拒绝管理员或用户登录令牌。此检查不验证签名，最终由腾讯云验证。')
 data.mkdir(parents=True,exist_ok=True,mode=0o700)
 key=secrets.token_hex(32)
 # Write once and restrict local access. Neither key is printed or sent anywhere.
 fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w',encoding='utf8') as f:json.dump({'platform_id':platform,'publishable_key':publishable,'gateway_key':key},f)
 digest=hashlib.sha256(key.encode()).hexdigest()
 sql=f"""-- Contains only the hash, never the gateway secret. Run in YOUR SQL editor.
BEGIN;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',{quote(subject)},'role','authenticated')::text,true);
SELECT set_config('request.jwt.claim.sub',{quote(subject)},true);
SELECT public.st_qq_gateway_register({quote(app)},{quote(digest)});
INSERT INTO public.st_qq_notification_settings(gateway_id,owner_id,enabled,approval_enabled,approval_activated_at,result_enabled,result_activated_at)
SELECT g.id,public.st_actor(),true,true,now(),true,now() FROM public.st_qq_gateways g WHERE g.app_id={quote(app)};
COMMIT;
"""
 registration=data/'REGISTER_GATEWAY.sql';registration.write_text(sql,encoding='utf8');registration.chmod(0o600)
 for plugin in plugins:
  dest=data/'plugins'/plugin
  shutil.copytree(source/'bot/plugins'/plugin,dest)
 state=data/'subtitle_notifications.json'
 state.write_text(json.dumps({'enabled':False,'approval_enabled':True,'result_enabled':True,'cleanup_enabled':False}),encoding='utf8');state.chmod(0o600)
 print('已安装插件并保存私密配置；尚未联网或发送 QQ 消息。')
 print('请在自己的 SQL 编辑器执行 '+str(registration)+'，然后重启 AstrBot 并按教程绑定。')
 print('源视频自动清理默认关闭；确认 7 天保留规则后按维护文档单独启用。')
if __name__=='__main__':main()

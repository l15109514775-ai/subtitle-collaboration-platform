"""Enable the already-authorized seven-day cleanup, without resetting state."""
import argparse,json,os
from pathlib import Path
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--data',type=Path,required=True);p.add_argument('--confirm-seven-day-policy',action='store_true');p.add_argument('--disable',action='store_true');a=p.parse_args()
 if not a.disable and not a.confirm_seven_day_policy:p.error('Enabling requires --confirm-seven-day-policy after reviewing the retention policy and database configuration')
 path=a.data.resolve()/'subtitle_notifications.json'
 state=json.loads(path.read_text(encoding='utf8'))
 if not a.disable and not state.get('owner_sender'):raise SystemExit('Bind the owner and notification destination first')
 state['cleanup_enabled']=not a.disable
 temp=path.with_suffix('.new');fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w',encoding='utf8') as f:json.dump(state,f);f.flush();os.fsync(f.fileno())
 os.replace(temp,path)
 print('Cleanup enabled for the next scheduled check' if not a.disable else 'Cleanup disabled; history preserved')
if __name__=='__main__':main()

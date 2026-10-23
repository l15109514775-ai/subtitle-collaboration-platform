"""Explicit commands only. No LLM tool, web login token or business mutations."""
import hashlib
import re

SITE = 'https://example-site.tcloudbaseapp.com/'
GATEWAY = 'https://example-env.api.tcloudbasegateway.com'
HELP = ('字幕组指令（请私聊使用）：\n字幕绑定\n字幕账号\n字幕项目\n我的任务\n待领任务\n任务详情 完整任务ID\n字幕解绑 确认\n网站：' + SITE)
MENU = ('字幕助手 · 功能菜单\n\n'
        '聊天问答：在群里 @我 加上问题。\n'
        '账号绑定：私聊发送「字幕绑定」，再登录网站确认。\n'
        '任务查询：私聊发送「字幕项目」「我的任务」「待领任务」或「任务详情 完整任务ID」。\n'
        '使用帮助：私聊发送「字幕帮助」。\n\n'
        '任务认领、交付、审核与字幕申请请在字幕组网站操作。')
COMMANDS = {'字幕绑定':'bind','字幕账号':'status','字幕项目':'projects','我的任务':'mine',
            '待领任务':'tasks','任务详情':'detail','字幕解绑':'unlink','字幕帮助':'help',
            '菜单':'menu','帮助':'menu','help':'menu'}
STATES = {'open':'待认领','claimed':'进行中','submitted':'待审核','approved':'已通过','archived':'已归档'}

def parse(text):
    parts = text.strip().removeprefix('/').split(maxsplit=1)
    if not parts or parts[0] not in COMMANDS:
        return None
    return COMMANDS[parts[0]], parts[1].strip() if len(parts)>1 else ''

def identity(platform_id, sender):
    return hashlib.sha256(('qq-c2c\0'+platform_id+'\0'+sender).encode()).hexdigest()

def clean(value, limit=160):
    return re.sub(r'[\x00-\x1f\x7f]', ' ', str(value))[:limit]

def render(action, value):
    if value.get('error'):
        return {'too_many_requests':'请求较多，请一分钟后再试。','invalid_task':'请提供完整任务 UUID。'}.get(value['error'],'查询未完成，请到网站查看。')
    state=value.get('state')
    if state=='pending':
        return ('请登录字幕组网站，打开「QQ 账号绑定」，粘贴下方绑定码并确认。五分钟内有效，请勿转发：\n'
                +value['code']+'\n'+SITE)
    if state=='already_bound':
        return '此 QQ 已绑定，请发送「字幕账号」查看。需要换绑时先解除原绑定。'
    if state=='unbound':
        return '当前未绑定网站账号。发送「字幕绑定」开始。'
    if state=='bound':
        return '已绑定网站成员：'+clean(value.get('name',''))
    if 'projects' in value:
        return '可访问项目（最多20项）：\n'+'\n'.join(clean(x['title'])+'\nID '+x['id'] for x in value['projects']) if value['projects'] else '当前没有可访问的项目。'
    tasks=value.get('tasks',[])
    if not tasks:
        return '没有符合条件的任务，或你无权查看。'
    lines=[]
    for t in tasks:
        lines.append(clean(t['title'])+' ['+STATES.get(t['state'],'未知状态')+']\n项目：'+clean(t['project_title'])+'\nID '+t['id'])
        if action=='detail':
            lines.append(clean(t.get('description') or '暂无说明',1000))
    return '任务查询（最多20项）：\n'+'\n\n'.join(lines)


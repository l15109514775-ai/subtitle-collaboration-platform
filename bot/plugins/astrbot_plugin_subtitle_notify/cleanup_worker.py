"""Exact-object Storage API cleanup; no arbitrary paths, credentials in logs or model calls."""
import asyncio
import json
import re
from urllib.parse import quote
from uuid import UUID
import aiohttp

BASE='https://example-env.api.tcloudbasegateway.com'
RPC=BASE+'/v1/rdb/rest/rpc/st_purge_worker'

def validate(value):
    if not isinstance(value,dict) or not isinstance(value.get('idle'),bool):raise ValueError('Invalid cleanup response')
    if value['idle']:return []
    UUID(value['job_id'])
    if value.get('completed') is True:return []
    if not re.fullmatch('[0-9a-f]{64}',value.get('capability','')):raise ValueError('Invalid cleanup lease')
    rows=value.get('objects')
    if not isinstance(rows,list) or not 1<=len(rows)<=20:raise ValueError('Invalid cleanup batch')
    seen=set()
    for row in rows:
        if set(row)!={'object_id','bucket_id','name'}:raise ValueError('Unexpected cleanup fields')
        UUID(row['object_id'])
        if row['bucket_id'] not in ('subtitle-inputs','subtitle-deliveries'):raise ValueError('Wrong cleanup bucket')
        name=row['name']
        if not isinstance(name,str) or len(name)>1024 or not re.fullmatch('[A-Za-z0-9._/-]+',name) or any(part in ('','.','..') for part in name.split('/')):raise ValueError('Unsafe cleanup path')
        if not re.fullmatch(r'(requests/)?[0-9a-f-]{36}/.+',name):raise ValueError('Wrong cleanup path scope')
        identity=(row['bucket_id'],name)
        if identity in seen:raise ValueError('Duplicate cleanup object')
        seen.add(identity)
    return rows

async def cleanup_pass(conf,sender,deadline,transport=None):
    """Deletion is reconciled by the next RPC's real storage metadata, never a guessed receipt."""
    async def operate(call):
        count=0
        for _ in range(100):
            if asyncio.get_running_loop().time()>=deadline:break
            result=await call('POST',RPC,{'Authorization':'Bearer '+conf['publishable_key']},
                {'p_key':conf['gateway_key'],'p_sender':sender})
            rows=validate(result)
            if result['idle']:break
            if result.get('completed'):count+=1;continue
            for bucket in sorted({r['bucket_id'] for r in rows}):
                names=[r['name'] for r in rows if r['bucket_id']==bucket]
                # Official manager-node PG deleteObjects contract: exact names despite 'prefixes'.
                await call('DELETE',BASE+'/v1/storages/object/'+quote(bucket,safe=''),
                    {'Authorization':'Bearer '+conf['publishable_key'],'x-subtitle-purge':result['capability']},
                    {'prefixes':names})
            await asyncio.sleep(0.1)
        return count
    if transport:return await operate(transport)
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as session:
        async def call(method,url,headers,body):
            async with session.request(method,url,headers=headers,json=body,allow_redirects=False) as response:
                raw=await response.content.read(1048577)
                if response.status<200 or response.status>=300:raise ValueError('Cleanup API rejected: HTTP '+str(response.status))
                if len(raw)>1048576:raise ValueError('Oversized cleanup response')
                return json.loads(raw) if raw else {}
        return await operate(call)

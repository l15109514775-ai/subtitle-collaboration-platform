// DOM integration simulation, not a claim of live-site deployment/browser media.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom'); // Test-only jsdom==26.1.0 in work directory.

(async () => {
  const dom = new JSDOM('<main id="board-view"><p>Existing board</p></main><button id="logout">Logout</button>', {
    url: 'https://fixture.invalid/', runScripts: 'outside-only'
  });
  const w = dom.window;
  const calls = [];
  const taskId = '11111111-1111-4111-8111-111111111111';
  const artifactId = '22222222-2222-4222-8222-222222222222';
  const jobs = [{id: 'fixture', project_id: 'project', project_name: '<img src=x onerror=alert(1)>',
    state: 'succeeded', delivery_id: 'delivery', text_requests: 6, qwen_requests: 0,
    media: [{id: 'media', role: 'subtitled', task_id: taskId, artifact_id: artifactId}]}];
  w.data = {me: {owner: true}, tasks: [{id: taskId}]};
  w.rpc = async (name, payload) => {
    calls.push([name, payload]);
    if (name === 'st_cloud_clip_board') return jobs;
    if (name === 'st_cloud_clip_create') return {state: 'queued'};
    throw Error('unexpected RPC');
  };
  w.load = async () => calls.push(['old-load']);
  w.logout = () => {calls.push(['old-logout']); w.data.me = null;};
  w.openTask = async id => calls.push(['open-task', id]);
  w.previewMedia = async id => calls.push(['preview-media', id]);
  w.MediaFiles = {hash: async () => 'a'.repeat(64)};
  w.eval(fs.readFileSync(path.join(__dirname, 'website/cloud-clips.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(__dirname, 'website/cloud-clips-host.js'), 'utf8'));
  await w.load();
  assert.equal(w.document.querySelectorAll('.cloud-clips').length, 1);
  assert.equal(w.document.querySelector('main').firstElementChild.className, 'cloud-clips');
  assert.equal(w.document.querySelectorAll('.cloud-clips img').length, 0, 'source title must be text');
  const preview = [...w.document.querySelectorAll('.cloud-clips button')].find(b => b.textContent === '播放中文字幕成片');
  preview.click(); await new Promise(resolve => setTimeout(resolve, 0));
  assert(calls.some(c => c[0] === 'open-task' && c[1] === taskId));
  assert(calls.some(c => c[0] === 'preview-media' && c[1] === artifactId));
  const form = w.document.querySelector('.cloud-clips__form');
  form.querySelector('input[type=url]').value = 'https://www.youtube.com/live/PTL-ZkyrSPA';
  form.querySelectorAll('input')[1].value = '浮気判定';
  form.dispatchEvent(new w.Event('submit', {bubbles: true, cancelable: true}));
  await new Promise(resolve => setTimeout(resolve, 0));
  const create = calls.find(c => c[0] === 'st_cloud_clip_create');
  assert(create); assert.equal(create[1].p_max_clip_seconds, 4200);
  assert.equal(create[1].p_source_url, 'https://www.youtube.com/watch?v=PTL-ZkyrSPA');
  await w.load(); assert.equal(w.document.querySelectorAll('.cloud-clips').length, 1);
  w.document.getElementById('logout').click();
  assert.equal(w.document.querySelectorAll('.cloud-clips').length, 0);
  assert(calls.some(c => c[0] === 'old-logout'));
  console.log('classic_script_mount_click_dispatch_load_logout_dom_tests_passed');
  dom.window.close();
})().catch(error => {console.error(error); process.exitCode = 1;});


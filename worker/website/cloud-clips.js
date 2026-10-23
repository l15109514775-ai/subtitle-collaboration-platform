/* New board section only. Host app supplies its existing authenticated rpc,
   load/logout lifecycle and verified private streaming player. No tokens here.
   Dedicated clip schema reviewed; media HTTP acceptance is tracked separately. */
function mountCloudClips({boardView, rpc, isOwner, openMedia, onError,
                                hashFile, uploadInputPart, signInputPart, uploadSourcesEnabled = false}) {
  if (!(boardView instanceof Element) || typeof rpc !== 'function') {
    throw new Error('cloud_clips_host_adapter_required');
  }
  const section = document.createElement('section');
  section.className = 'cloud-clips';
  section.setAttribute('aria-label', '云端剪辑');
  const heading = document.createElement('h2');
  heading.textContent = '云端剪辑';
  section.append(heading);
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  section.append(status);
  let active = true;
  let generation = 0;
  const cards = document.createElement('div');
  cards.className = 'cloud-clips__cards';
  const form = document.createElement('form');
  form.className = 'cloud-clips__form';
  const url = document.createElement('input');
  url.type = 'url'; url.required = true;
  url.setAttribute('aria-label', 'YouTube 公开视频地址');
  url.placeholder = 'YouTube 公开视频地址';
  const topic = document.createElement('input');
  topic.required = true; topic.maxLength = 100;
  topic.setAttribute('aria-label', '剪辑话题');
  topic.placeholder = '剪辑话题，例如：浮気判定';
  const submit = document.createElement('button');
  submit.type = 'submit'; submit.textContent = '登记云端剪辑任务';
  const scope = document.createElement('p');
  scope.textContent = '一次处理一个完整片段，最长 70 分钟，上限为 20 次文字、2 次千问请求。登记后还需在 Codex 云端启动执行；AI 初稿完成后开放人工听校。';
  const sourceKind = document.createElement('select');
  sourceKind.setAttribute('aria-label', '源素材方式');
  for (const [value, label] of [['youtube', '从公开 YouTube 获取'], ...(uploadSourcesEnabled ? [['upload', '上传已有合法原视频']] : [])]) {
    const option = document.createElement('option'); option.value = value; option.textContent = label;
    sourceKind.append(option);
  }
  form.append(url, topic, sourceKind, submit, scope);
  form.hidden = !isOwner();
  section.append(form, cards);
  boardView.append(section);

  function fail() {
    if (!active) return;
    status.textContent = '云端剪辑暂时不可用，请稍后刷新。';
    // Keep arbitrary backend error strings/capabilities out of DOM and console.
    if (onError) onError('cloud_clips_unavailable');
  }

  const stateLabels = {
    waiting_source: '等待私有源素材上传', queued: '等待云端处理', running: '云端处理中', waiting_configuration: '等待源视频或环境配置',
    waiting_reconciliation: '等待请求核对', failed: '处理停止', cancelled: '已取消',
    succeeded: 'AI 初稿已交付，待人工听校'
  };

  async function load() {
    const token = ++generation;
    try {
      // The backend must apply project_access, omit capability paths and secrets.
      const jobs = await rpc('st_cloud_clip_board', {});
      if (!active || token !== generation) return;
      if (!Array.isArray(jobs)) throw new Error('invalid_clip_board');
      cards.replaceChildren();
      for (const job of jobs) {
        const article = document.createElement('article');
        article.className = 'cloud-clips__card';
        const title = document.createElement('h3');
        title.textContent = job.project_name || job.source_title || '云端剪辑';
        const state = document.createElement('p');
        state.textContent = stateLabels[job.state] || '状态待核对';
        const progress = document.createElement('p');
        const text = Number.isSafeInteger(job.text_requests) ? job.text_requests : 0;
        const qwen = Number.isSafeInteger(job.qwen_requests) ? job.qwen_requests : 0;
        progress.textContent = `文字请求 ${text} / 20 · 千问请求 ${qwen} / 2`;
        article.append(title, state, progress);
        if (job.state === 'waiting_configuration') {
          const explanation = document.createElement('p');
          explanation.textContent = '尚未取得可处理的源视频，或云端配置需要处理；此状态不表示已有成品。';
          article.append(explanation);
        }
        if (job.state === 'waiting_source' && isOwner() && uploadSourcesEnabled) addSourceUpload(article, job);
        if (job.state === 'succeeded' && job.delivery_id) {
          const review = document.createElement('p');
          review.textContent = '剪辑、字幕与封面已生成。需要人工听校，不计人工贡献或积分。';
          article.append(review);
          for (const [role, label] of [['clean', '查看原片'], ['subtitled', '播放中文字幕成片'], ['cover', '查看封面']]) {
            const media = (job.media || []).find(item => item.role === role);
            if (!media || !media.id || typeof openMedia !== 'function') continue;
            const button = document.createElement('button');
            button.type = 'button'; button.textContent = label;
            button.addEventListener('click', async () => {
              button.disabled = true;
              try {
                // Preview uses authorized streaming; full-file checks belong to download.
                await openMedia({projectId: job.project_id, deliveryId: job.delivery_id,
                                 mediaId: media.id, taskId: media.task_id,
                                 artifactId: media.artifact_id, role});
              } catch { fail(); }
              finally { if (active) button.disabled = false; }
            });
            article.append(button);
          }
          const reports = document.createElement('button');
          reports.type = 'button'; reports.textContent = '获取字幕与报告';
          const filesBox = document.createElement('div');
          reports.onclick = async () => {
            reports.disabled = true;
            try {
              const bundle = await rpc('st_cloud_clip_files', {p_job: job.id});
              if (!active) return;
              if (!Array.isArray(bundle.files)) throw new Error('invalid_files');
              filesBox.replaceChildren();
              for (const file of bundle.files) {
                const save = document.createElement('button');
                save.type = 'button'; save.textContent = '下载 ' + file.name;
                save.onclick = async () => {
                  save.disabled = true;
                  try {
                    const bytes = Uint8Array.from(atob(file.base64), c => c.charCodeAt(0));
                    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('');
                    if (hash !== file.sha256 || bytes.length !== file.bytes) throw new Error('file_mismatch');
                    if (!active) return;
                    const href = URL.createObjectURL(new Blob([bytes], {type: 'application/octet-stream'}));
                    const anchor = document.createElement('a');
                    anchor.href = href; anchor.download = file.name; anchor.click();
                    setTimeout(() => URL.revokeObjectURL(href), 60000);
                  } catch { fail(); }
                  finally { if (active) save.disabled = false; }
                };
                filesBox.append(save);
              }
            } catch { fail(); }
            finally { if (active) reports.disabled = false; }
          };
          article.append(reports, filesBox);
        }
        cards.append(article);
      }
      status.textContent = jobs.length ? '' : '暂无云端剪辑任务。';
      form.hidden = !isOwner();
    } catch { if (token === generation) fail(); }
  }

  function fileDuration(file) {
    return new Promise((resolve, reject) => {
      const media = document.createElement(file.type.startsWith('audio/') ? 'audio' : 'video');
      const objectURL = URL.createObjectURL(file);
      const finish = (error, duration) => {
        clearTimeout(timer); media.onloadedmetadata = null; media.onerror = null;
        URL.revokeObjectURL(objectURL); media.removeAttribute('src'); media.load();
        error ? reject(error) : resolve(duration);
      };
      const timer = setTimeout(() => finish(new Error('metadata_timeout')), 30000);
      media.onloadedmetadata = () => Number.isFinite(media.duration) && media.duration > 0
        ? finish(null, media.duration) : finish(new Error('invalid_duration'));
      media.onerror = () => finish(new Error('unreadable_source_metadata'));
      media.preload = 'metadata'; media.src = objectURL;
    });
  }

  function addSourceUpload(article, job) {
    const upload = document.createElement('form');
    upload.className = 'cloud-clips__form';
    const fileInput = document.createElement('input');
    fileInput.type = 'file'; fileInput.required = true;
    fileInput.accept = '.mp4,.webm,.m4a,.mp3,.wav';
    fileInput.setAttribute('aria-label', '已有合法原始素材');
    const kind = document.createElement('select');
    kind.setAttribute('aria-label', '素材是否已经裁切');
    for (const [value, label] of [['full', '原直播完整源文件'], ['topic', '已裁切的话题素材']]) {
      const option = document.createElement('option'); option.value = value; option.textContent = label; kind.append(option);
    }
    const offset = document.createElement('input');
    offset.type = 'text'; offset.value = '00:00:00';
    offset.setAttribute('aria-label', '素材开头在原直播中的时间，例如 02:24:33');
    const hint = document.createElement('p');
    hint.textContent = '最大 4 GiB；原直播可长达 6 小时，已裁切话题最长 70 分钟。请填写原直播起点。只有音轨可用于识别，仍需原视频才能交付成片。';
    const button = document.createElement('button'); button.type = 'submit'; button.textContent = '校验并上传私有源素材';
    const feedback = document.createElement('p'); feedback.setAttribute('role', 'status');
    upload.append(fileInput, kind, offset, hint, button, feedback); article.append(upload);
    upload.addEventListener('submit', async event => {
      event.preventDefault();
      if (!active || !isOwner()) return;
      const file = fileInput.files[0];
      if (!file || !hashFile || !uploadInputPart || !signInputPart) {
        feedback.textContent = '源素材上传尚未配置，请联系组长。'; return;
      }
      button.disabled = true;
      try {
        if (file.size <= 0 || file.size > 4294967296) throw new Error('source_size_limit');
        const match = /^(\d{1,2}):([0-5]\d):([0-5]\d)$/.exec(offset.value.trim());
        if (!match) throw new Error('source_offset_invalid');
        const seconds = Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
        const duration = await fileDuration(file);
        const mime = ({mp4: 'video/mp4', webm: 'video/webm', m4a: 'audio/mp4', mp3: 'audio/mpeg', wav: 'audio/wav'})[file.name.split('.').pop().toLowerCase()];
        if (!mime || duration > 21600 || (kind.value === 'topic' && duration > 4200) ||
            (kind.value === 'full' && seconds !== 0)) throw new Error('source_duration_or_type_invalid');
        feedback.textContent = '正在计算完整 SHA256…';
        const sha = await hashFile(file);
        if (!active) return;
        const reservation = await rpc('st_cloud_clip_prepare_upload', {p_job: job.id, p_filename: file.name,
          p_mime: mime, p_bytes: file.size, p_sha256: sha, p_duration: duration,
          p_is_topic_only: kind.value === 'topic', p_original_offset: seconds});
        if (reservation.state !== 'uploading' || reservation.overwrite !== false ||
            reservation.part_bytes !== 4194304) throw new Error('source_reservation_invalid');
        const sources = []; let completed = 0;
        for (const part of reservation.parts) {
          if (!active) throw new Error('logged_out');
          const bytes = file.slice(completed, completed + part.byte_size);
          if (bytes.size !== part.byte_size) throw new Error('source_part_size_changed');
          await uploadInputPart({bucket: 'subtitle-inputs', path: part.path, mime, bytes, overwrite: false});
          if (!active) throw new Error('logged_out');
          const signed = await signInputPart(part.path, 82800);
          sources.push({index: part.index, byte_size: part.byte_size, url: signed});
          completed += part.byte_size;
          if (active) feedback.textContent = `已上传 ${Math.round(completed / file.size * 100)}%`;
        }
        if (completed !== file.size) throw new Error('source_total_size_changed');
        if (!active) throw new Error('logged_out');
        await rpc('st_cloud_clip_source_ready', {p_job: job.id, p_sources: sources,
          p_expires_at: new Date(Date.now() + 22 * 3600000).toISOString()});
        if (active) await load();
      } catch {
        if (active) feedback.textContent = '源素材尚未登记完成。请检查素材、起点和上传状态；不会生成不完整交付。';
      } finally { if (active) button.disabled = false; }
    });
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!active || !isOwner()) return;
    let canonical;
    try {
      const parsed = new URL(url.value.trim());
      const match = parsed.pathname.match(/^\/live\/([A-Za-z0-9_-]{11})$/);
      const id = parsed.pathname === '/watch' ? parsed.searchParams.get('v') : match?.[1];
      if (parsed.protocol !== 'https:' || parsed.hostname !== 'www.youtube.com' ||
          parsed.username || parsed.password || parsed.port || !/^[A-Za-z0-9_-]{11}$/.test(id || '')) {
        throw new Error('invalid_source');
      }
      canonical = `https://www.youtube.com/watch?v=${id}`;
      if (!topic.value.trim()) throw new Error('missing_topic');
    } catch {
      status.textContent = '请填写标准 YouTube watch/live 地址和明确话题。';
      return;
    }
    submit.disabled = true;
    try {
      await rpc(sourceKind.value === 'upload' ? 'st_cloud_clip_create_upload' : 'st_cloud_clip_create', {p_source_url: canonical, p_topic: topic.value.trim(),
                  p_max_clip_seconds: 4200, p_max_text_requests: 20, p_max_qwen_requests: 2});
      if (active) { form.reset(); await load(); }
    } catch { fail(); }
    finally { if (active) submit.disabled = false; }
  });

  // Host calls load from its existing load() and destroy synchronously on logout.
  return {load, destroy() {
    active = false; ++generation;
    url.value = ''; topic.value = ''; cards.replaceChildren(); section.remove();
  }};
}
window.CloudClips = Object.freeze({mount: mountCloudClips});


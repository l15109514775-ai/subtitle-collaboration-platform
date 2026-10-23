/* Classic defer adapter. Load AFTER app, chunked-media.js and cloud-clips.js.
   Uses the host's existing authenticated request/rpc and logout lifecycle. */
(() => {
  'use strict';
  let panel = null;
  const viewers = new Set();
  const aborts = new Set();
  const taskIsLoaded = id => typeof data !== 'undefined' && (data.tasks || []).some(t => t.id === id);

  async function showMedia({taskId, artifactId}) {
    if (!taskId || !artifactId) throw new Error('交付文件记录尚未就绪');
    if (taskIsLoaded(taskId)) {
      await openTask(taskId);
      await previewMedia(artifactId);
      return;
    }
    // The board panel can point at a project other than the currently selected
    // board. Query its existing authorized task detail without mutating data or
    // inventing task state, then use the same streaming implementation.
    const task = await rpc('st_task_detail', {p_task: taskId});
    const artifact = (task.artifacts || []).find(a => a.id === artifactId);
    if (!artifact) throw new Error('交付文件记录不可用');
    let url;
    if (artifact.parts?.length) {
      url = await chunkedMediaURL(artifact);
    } else {
      const signed = await request('/v1/storages/object/sign/subtitle-deliveries/' + MediaFiles.objectPath(artifact.object_path), {expiresIn: 600});
      url = new URL(signed.fullSignedURL || signed.signedURL, BASE);
      if (url.origin !== BASE) throw new Error('文件服务域名不匹配');
    }
    const dialog = document.createElement('dialog'); dialog.className = 'cloud-clips__viewer';
    const heading = document.createElement('h2'); heading.textContent = artifact.file_name;
    const media = document.createElement(artifact.mime_type.startsWith('video/') ? 'video' : 'img');
    media.src = url.href;
    if (media.tagName === 'VIDEO') { media.controls = true; media.preload = 'metadata'; }
    else media.alt = artifact.file_name;
    const message = document.createElement('p'); message.setAttribute('role', 'status');
    const download = document.createElement('button'); download.textContent = '下载并核验原文件';
    const close = document.createElement('button'); close.textContent = '关闭'; close.onclick = () => dialog.close();
    download.onclick = async () => {
      download.disabled = true;
      const controller = new AbortController(); aborts.add(controller);
      try {
        let handle = null;
        if (artifact.byte_size > 134217728) {
          if (!window.showSaveFilePicker) throw new Error('大文件下载需要支持保存文件的新版 Chrome 或 Edge');
          handle = await window.showSaveFilePicker({suggestedName: artifact.file_name});
        }
        message.textContent = '正在下载和核验，请保持登录…';
        const response = await fetch(url.href, {credentials: 'omit', cache: 'no-store', signal: controller.signal});
        if (!response.ok) throw new Error('读取失败');
        let saved;
        if (handle) {
          const writable = await handle.createWritable();
          try { await response.body.pipeTo(writable, {signal: controller.signal}); }
          catch (error) { try { await writable.abort(); } catch {} throw error; }
          saved = await handle.getFile();
        } else saved = await response.blob();
        if (saved.size !== artifact.byte_size || await MediaFiles.hash(saved, () => {}, controller.signal) !== artifact.sha256) {
          throw new Error('下载的完整文件 SHA256 或大小不匹配，请勿使用该文件');
        }
        if (!handle) {
          const href = URL.createObjectURL(saved); const anchor = document.createElement('a');
          anchor.href = href; anchor.download = artifact.file_name; anchor.click();
          setTimeout(() => URL.revokeObjectURL(href), 60000);
        }
        message.textContent = '完整文件 SHA256 核验通过。';
      } catch (error) {
        if (!controller.signal.aborted) message.textContent = error.message || '下载尚未完成。';
      } finally { aborts.delete(controller); download.disabled = false; }
    };
    dialog.append(heading, media, message, download, close); document.body.append(dialog); viewers.add(dialog);
    dialog.addEventListener('close', () => {
      media.removeAttribute('src'); if (media.tagName === 'VIDEO') media.load();
      viewers.delete(dialog); dialog.remove();
    }, {once: true});
    dialog.showModal();
  }

  async function refresh() {
    const board = document.getElementById('board-view');
    if (!board || typeof data === 'undefined' || !data.me || !window.CloudClips) return;
    if (!panel) {
      panel = window.CloudClips.mount({boardView: board, rpc,
        uploadSourcesEnabled: window.CLOUD_CLIP_UPLOAD_SOURCES === true,
        isOwner: () => !!data?.me?.owner,
        openMedia: showMedia,
        hashFile: file => MediaFiles.hash(file, () => {}),
        uploadInputPart: async ({path, mime, bytes}) => {
          const controller = new AbortController(); aborts.add(controller);
          try {
            const response = await fetch(BASE + '/v1/storages/object/subtitle-inputs/' + MediaFiles.objectPath(path), {
              method: 'POST', headers: {'Authorization': 'Bearer ' + token, 'Content-Type': mime, 'x-upsert': 'false'},
              body: bytes, signal: controller.signal
            });
            if (!response.ok) throw new Error('源素材上传未完成');
          } finally { aborts.delete(controller); }
        },
        signInputPart: async (path, expiresIn) => {
          const result = await request('/v1/storages/object/sign/subtitle-inputs/' + MediaFiles.objectPath(path), {expiresIn});
          const url = new URL(result.fullSignedURL || result.signedURL, BASE);
          if (url.origin !== BASE) throw new Error('源素材服务域名不匹配');
          return url.href;
        }
      });
      board.prepend(board.querySelector('.cloud-clips'));
    }
    await panel.load();
  }

  const previousLoad = load;
  load = async function (...args) {
    const result = await previousLoad.apply(this, args);
    try { await refresh(); } catch {} // Core board remains usable on RPC deployment mismatch.
    return result;
  };
  const previousLogout = logout;
  logout = function (...args) {
    for (const controller of aborts) controller.abort(); aborts.clear();
    for (const dialog of viewers) dialog.close(); viewers.clear();
    if (panel) panel.destroy(); panel = null;
    return previousLogout.apply(this, args);
  };
  const logoutButton = document.getElementById('logout');
  if (logoutButton) logoutButton.onclick = logout;
  void refresh().catch(() => {});
})();


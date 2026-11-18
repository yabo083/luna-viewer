// chatluna-plugin-media-bridge
// 把 agent 工作区（data/chatluna/agents-work）里的文件通过 Bearer 保护的
// GET /api/workspace?path=<相对路径> 暴露给客户端（移动端渲染消息里的图片）。
// 只读；路径必须落在工作区内。后续版本会在这里加：上传、临时签名、缩略图。
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve, sep } from 'node:path'

export const name = 'chatluna-workspace-files'
export const inject = ['server']

const MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.json': 'application/json'
}

export function apply(ctx) {
  const root = resolve(process.env.CHATLUNA_WORKSPACE ?? join(process.cwd(), 'data/chatluna/agents-work'))
  ctx.logger('media-bridge').info('serving workspace files from %s', root)

  const serve = async (relative, res) => {
    if (!relative) {
      res.status = 400
      res.body = 'missing path'
      return
    }
    const target = resolve(root, normalize(relative))
    if (target !== root && !target.startsWith(root + sep)) {
      res.status = 400
      res.body = 'path outside workspace'
      return
    }
    const info = await stat(target).catch(() => undefined)
    if (info === undefined || !info.isFile()) {
      res.status = 404
      res.body = 'file not found'
      return
    }
    res.status = 200
    res.headers.set('content-type', MIME[extname(target).toLowerCase()] ?? 'application/octet-stream')
    res.headers.set('cache-control', 'public, max-age=3600')
    res.body = await readFile(target)
  }

  ctx.server.get('/api/workspace/:name', async (req, res) => {
    const raw = req.params?.name ?? ''
    let relative
    try {
      relative = decodeURIComponent(raw)
    } catch {
      relative = raw
    }
    return serve(relative, res)
  })

  // 路径参数里的 `/` 在部分路由实现下拿不到，查询参数作为稳定形态。
  ctx.server.get('/api/workspace', async (req, res) => {
    const raw = req.query?.get?.('path') ?? ''
    return serve(raw, res)
  })

}

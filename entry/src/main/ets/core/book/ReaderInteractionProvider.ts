import { BookSource } from '../../model/data/Book';
import { HttpClient } from '../http/HttpClient';
import { BookSourceRuntimeSnapshotStore } from './BookSourceRuntimeSnapshot';

export class ReaderParagraphInteraction {
  order: number = -1;
  paragraphId: string = '';
  count: number = 0;
  target: string = 'paragraph';
}

export class ReaderInteractionBundle {
  providerId: string = '';
  bookId: string = '';
  chapterId: string = '';
  actions: ReaderParagraphInteraction[] = [];
}

export class ReaderInteractionPanel {
  html: string = '';
  baseUrl: string = '';
}

export interface ReaderInteractionProvider {
  id: string;
  matches(source: BookSource): boolean;
  fetch(source: BookSource, bookId: string, chapterId: string): Promise<ReaderInteractionBundle | null>;
  expandAction(source: BookSource, compactUrl: string): string;
  buildPanel(actionUrl: string): ReaderInteractionPanel | null;
}

class ReaderInteractionCacheEntry {
  bundle: ReaderInteractionBundle | null = null;
  expiresAt: number = 0;
}

class ShuqiReaderInteractionProvider implements ReaderInteractionProvider {
  id: string = 'shuqi-comments';

  matches(source: BookSource): boolean {
    const script = source.jsLib || '';
    return /\bSQ_COMMENT_API_BASE\b/.test(script) && /\b(?:sqDecorateContent|showSqComments)\b/.test(script);
  }

  async fetch(source: BookSource, bookId: string, chapterId: string): Promise<ReaderInteractionBundle | null> {
    const config = this.config(source);
    if (!config['apiBase'] || !config['apiKey'] || !bookId || !chapterId) return null;
    const response = await new HttpClient(8000).execute({
      url: `${config['apiBase']}/v1/reader/render-ext`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ bookId: bookId, chapterId: chapterId, apiKey: config['apiKey'] }),
      maxResponseBytes: 2 * 1024 * 1024
    });
    if (!response.body) throw new Error(response.error || `评论接口请求失败：${response.statusCode}`);
    const root = this.objectRecord(JSON.parse(response.body.replace(/^\uFEFF/, '')) as Object);
    if (root['ok'] !== true && String(root['ok'] || '') !== 'true') {
      throw new Error(String(root['error'] || '评论接口返回异常'));
    }
    const outer = this.objectRecord(root['data']);
    const data = this.objectRecord(outer['data'] || outer['Data']);
    const ext = this.objectRecord(data['bookChapterExtInfo'] || data['BookChapterExtInfo']);
    const paragraphs = this.objectList(ext['paragraphList'] || ext['ParagraphList']);
    const bundle = new ReaderInteractionBundle();
    bundle.providerId = this.id;
    bundle.bookId = bookId;
    bundle.chapterId = chapterId;
    for (const value of paragraphs) {
      const record = this.objectRecord(value);
      const order = Number(record['orderId'] ?? record['OrderId'] ?? -1);
      const count = Number(record['commentCount'] || record['CommentCount'] || 0);
      if (count <= 0 || order < 0) continue;
      const action = new ReaderParagraphInteraction();
      action.order = order;
      action.count = count;
      action.paragraphId = String(record['paragraphId'] || record['ParagraphId'] || `p${order}`);
      action.target = order === 0 ? 'chapterTitle' : 'paragraph';
      bundle.actions.push(action);
    }
    return bundle.actions.length > 0 ? bundle : null;
  }

  expandAction(source: BookSource, compactUrl: string): string {
    const genericMatch = /^legado-provider-action:\/\/shuqi-comments\/([^/]+)\/([^/]+)\/([^?]+)\?mode=([^&#]+)/i
      .exec(compactUrl || '');
    const legacyMatch = /^legado-shuqi-comment:\/\/([^/]+)\/([^/]+)\/([^?]+)\?mode=([^&#]+)/i
      .exec(compactUrl || '');
    const match = genericMatch || legacyMatch;
    if (!match || !match[1] || !match[2] || !match[3]) return compactUrl;
    let bookId = '';
    let chapterId = '';
    let paragraphId = '';
    let mode = 'paragraph';
    try {
      bookId = decodeURIComponent(match[1]);
      chapterId = decodeURIComponent(match[2]);
      paragraphId = decodeURIComponent(match[3]);
      mode = decodeURIComponent(match[4] || 'paragraph') === 'chapterTitle' ? 'chapterTitle' : 'paragraph';
    } catch (_) {
      return '';
    }
    const config = this.config(source);
    return `https://shuqi.aadcn.cn/paragraph?legado_reader_shuqi=1` +
      `&apiKey=${encodeURIComponent(config['apiKey'] || '')}&bookId=${encodeURIComponent(bookId)}` +
      `&chapterId=${encodeURIComponent(chapterId)}&paragraphId=${encodeURIComponent(paragraphId)}` +
      `&mode=${encodeURIComponent(mode)}`;
  }

  buildPanel(actionUrl: string): ReaderInteractionPanel | null {
    if (!/^https:\/\/shuqi\.aadcn\.cn\/paragraph\?/i.test(actionUrl || '') ||
      !/[?&]legado_reader_shuqi=1(?:&|$)/i.test(actionUrl || '')) {
      return null;
    }
    const apiKey = JSON.stringify(this.queryValue(actionUrl, 'apiKey'));
    const bookId = JSON.stringify(this.queryValue(actionUrl, 'bookId'));
    const chapterId = JSON.stringify(this.queryValue(actionUrl, 'chapterId'));
    const paragraphId = JSON.stringify(this.queryValue(actionUrl, 'paragraphId'));
    const mode = JSON.stringify(this.queryValue(actionUrl, 'mode') || 'paragraph');
    const quoteText = JSON.stringify(this.queryValue(actionUrl, 'quoteText'));
    const panel = new ReaderInteractionPanel();
    panel.baseUrl = 'https://shuqi.aadcn.cn/';
    panel.html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" ` +
      `content="width=device-width,initial-scale=1,maximum-scale=1"><style>` +
      `:root{color-scheme:light dark;--bg:#f6f6f7;--card:#fff;--text:#202124;--muted:#777;` +
      `--line:#e7e7e9;--accent:#df493c;--reply:#f3f3f5}*{box-sizing:border-box}` +
      `body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,sans-serif}` +
      `header{position:sticky;top:0;z-index:2;padding:14px 15px 10px;background:var(--card);` +
      `border-bottom:1px solid var(--line)}h1{font-size:18px;margin:0 0 5px}.quote{display:none;margin:9px 0 4px;` +
      `padding:8px 10px;border-left:3px solid var(--accent);background:var(--reply);border-radius:0 7px 7px 0;` +
      `font-size:13px;line-height:1.55;white-space:pre-wrap}.subtitle{font-size:12px;color:var(--muted)}` +
      `.tabs{display:flex;gap:22px;margin-top:9px}.tab{border:0;border-bottom:2px solid transparent;padding:6px 0;` +
      `background:none;color:var(--muted);font-size:14px}.tab.active{color:var(--accent);border-color:var(--accent)}` +
      `main{padding:9px}.item,.section{padding:13px;margin-bottom:8px;border:1px solid var(--line);` +
      `border-radius:10px;background:var(--card)}.head{display:flex;align-items:center;gap:9px}.avatar{width:34px;` +
      `height:34px;border-radius:50%;object-fit:cover;background:var(--reply)}.identity{min-width:0;flex:1}` +
      `.name{font-size:14px;font-weight:650}.time,.likes{font-size:11px;color:var(--muted)}.text{margin-top:9px;` +
      `font-size:15px;line-height:1.65;white-space:pre-wrap;word-break:break-word}.replies{margin-top:9px;padding:7px 9px;` +
      `border-radius:7px;background:var(--reply);font-size:13px;line-height:1.6}.section h2{font-size:14px;color:var(--accent)}` +
      `.state{text-align:center;padding:38px 10px;color:var(--muted)}.error{color:#b42318}` +
      `@media(prefers-color-scheme:dark){:root{--bg:#111214;--card:#1c1d20;--text:#eceef1;` +
      `--muted:#a0a3a9;--line:#303238;--accent:#ff7165;--reply:#27282c}}` +
      `</style></head><body><header><h1 id="title">段评</h1><div id="quote" class="quote"></div>` +
      `<div id="subtitle" class="subtitle">加载中…</div><div id="tabs" class="tabs">` +
      `<button class="tab active" data-order="hot">最热</button><button class="tab" data-order="new">最新</button>` +
      `</div></header><main id="list"><div class="state">评论加载中…</div></main><script>` +
      `(function(){var API='https://shuqi.aadcn.cn',KEY=${apiKey},BID=${bookId},CID=${chapterId},` +
      `PID=${paragraphId},MODE=${mode},QUOTE=${quoteText};var list=document.getElementById('list'),` +
      `title=document.getElementById('title'),subtitle=document.getElementById('subtitle'),` +
      `tabs=document.getElementById('tabs'),quote=document.getElementById('quote');` +
      `if(QUOTE){quote.textContent=QUOTE;quote.style.display='block'}` +
      `function esc(v){return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;')` +
      `.replace(/>/g,'&gt;').replace(/"/g,'&quot;')}` +
      `function mediaUrl(v){var u=String(v==null?'':v).trim(),lower=u.toLowerCase();` +
      `if(u.indexOf('//')===0){u='https:'+u;lower=u.toLowerCase()}` +
      `if(lower.indexOf('http://img-tailor.11222.cn/')===0)u='https://'+u.substring(7);` +
      `lower=u.toLowerCase();return lower.indexOf('https:')===0||lower.indexOf('data:image/')===0?u:''}` +
      `function fail(e){list.innerHTML='<div class="state error">加载失败：'+esc(e&&e.message||e)+'</div>';` +
      `subtitle.textContent='请在书源登录面板检查“书旗评论 API Key”'}` +
      `function post(path,body){body=body||{};body.apiKey=KEY;return fetch(API+path,{method:'POST',` +
      `headers:{'Content-Type':'application/json','Accept':'application/json'},body:JSON.stringify(body),` +
      `cache:'no-store'}).then(function(r){return r.text()}).then(function(raw){var root=JSON.parse(String(raw||'{}')` +
      `.replace(/^\\uFEFF/,''));if(!root.ok)throw new Error(root.error||'评论接口返回异常');return root})}` +
      `function replyHtml(r){return '<div><b>'+esc(r&&r.nickname||'书友')+'</b>：'+` +
      `esc(r&&(r.text||r.richText)||'')+'</div>'}` +
      `function card(c){c=c||{};var photo=mediaUrl(c.userPhoto),avatar=photo?` +
      `'<img class="avatar" src="'+esc(photo)+'">':` +
      `'<span class="avatar"></span>',rs=c.replies&&c.replies.commentList||[],replies='';` +
      `for(var i=0;i<rs.length;i++)replies+=replyHtml(rs[i]);return '<article class="item"><div class="head">'+` +
      `avatar+'<div class="identity"><div class="name">'+esc(c.nickname||'书友')+'</div><div class="time">'+` +
      `esc(c.pubTime||'')+'</div></div><span class="likes">赞 '+Number(c.likes||0)+'</span></div>'+` +
      `'<div class="text">'+esc(c.text||c.richText||'')+'</div>'+(replies?'<div class="replies">'+replies+'</div>':'')+` +
      `'</article>'}` +
      `function comments(root){var outer=root.data||{},data=outer.data||outer.Data||{},arr=data.commentList||` +
      `data.CommentList||[],html='';for(var i=0;i<arr.length;i++)html+=card(arr[i]);return {html:html,count:arr.length}}` +
      `function load(order){list.innerHTML='<div class="state">评论加载中…</div>';post('/v1/comments/chapter-list',` +
      `{bookId:BID,chapterId:CID,paragraphId:PID,order:order,size:50}).then(function(root){var out=comments(root);` +
      `list.innerHTML=out.html||'<div class="state">暂无评论</div>';subtitle.textContent=(MODE==='chapterTitle'?'章节标题':` +
      `('第 '+String(PID).replace(/\\D/g,'')+' 段'))+' · 已加载 '+out.count+' 条'}).catch(fail)}` +
      `if(!KEY){fail(new Error('未配置书旗评论 API Key'));return}if(!BID||!CID||!PID){fail(new Error('评论定位参数不完整'));return}` +
      `title.textContent=MODE==='chapterTitle'?'章评':'段评';var bs=tabs.querySelectorAll('.tab');` +
      `for(var i=0;i<bs.length;i++)bs[i].onclick=function(){for(var j=0;j<bs.length;j++)bs[j].className='tab';` +
      `this.className='tab active';load(this.getAttribute('data-order'))};load('hot')})();` +
      `</script></body></html>`;
    return panel;
  }

  private config(source: BookSource): Record<string, string> {
    const baseMatch = (source.jsLib || '').match(/\bSQ_COMMENT_API_BASE\s*=\s*['"](https?:\/\/[^'"]+)['"]/i);
    const keyMatch = (source.jsLib || '').match(/\bSQ_COMMENT_API_KEY\s*=\s*['"]([^'"]*)['"]/i);
    return {
      apiBase: baseMatch && baseMatch[1] ? baseMatch[1].replace(/\/+$/, '') : '',
      apiKey: BookSourceRuntimeSnapshotStore.get(source).getString('书旗评论 API Key') ||
        (keyMatch && keyMatch[1] ? keyMatch[1] : '')
    };
  }

  private queryValue(url: string, key: string): string {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = new RegExp(`[?&]${escaped}=([^&#]*)`, 'i').exec(url || '');
    if (!match || !match[1]) return '';
    try {
      return decodeURIComponent(match[1].replace(/\+/g, ' '));
    } catch (_) {
      return match[1];
    }
  }

  private objectRecord(value: Object | undefined | null): Record<string, Object> {
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : {};
  }

  private objectList(value: Object | undefined | null): Object[] {
    return Array.isArray(value) ? value as Object[] : [];
  }
}

export class ReaderInteractionProviderRegistry {
  private static providers: ReaderInteractionProvider[] = [new ShuqiReaderInteractionProvider()];
  private static cache: Map<string, ReaderInteractionCacheEntry> = new Map();
  private static inFlight: Map<string, Promise<ReaderInteractionBundle | null>> = new Map();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly MAX_CACHE_ENTRIES: number = 64;

  static resolve(source: BookSource): ReaderInteractionProvider | null {
    for (const provider of this.providers) {
      if (provider.matches(source)) return provider;
    }
    return null;
  }

  static expandAction(source: BookSource, compactUrl: string): string {
    if (!/^legado-(?:provider-action|shuqi-comment):\/\//i.test(compactUrl || '')) return compactUrl;
    const provider = this.resolve(source);
    return provider ? provider.expandAction(source, compactUrl) : compactUrl;
  }

  static buildPanel(actionUrl: string): ReaderInteractionPanel | null {
    for (const provider of this.providers) {
      const panel = provider.buildPanel(actionUrl);
      if (panel) return panel;
    }
    return null;
  }

  static async fetch(source: BookSource, bookId: string, chapterId: string): Promise<ReaderInteractionBundle | null> {
    const provider = this.resolve(source);
    if (!provider || !bookId || !chapterId) return null;
    const revision = BookSourceRuntimeSnapshotStore.get(source).signature;
    const key = `${provider.id}:${source.bookSourceUrl || source.bookSourceName}:${bookId}:${chapterId}:${revision}`;
    const cached = this.cache.get(key);
    if (cached && cached.expiresAt > Date.now()) return cached.bundle;
    const active = this.inFlight.get(key);
    if (active) return await active;

    const task = provider.fetch(source, bookId, chapterId);
    this.inFlight.set(key, task);
    try {
      const bundle = await task;
      const entry = new ReaderInteractionCacheEntry();
      entry.bundle = bundle;
      entry.expiresAt = Date.now() + this.CACHE_TTL_MS;
      this.cache.delete(key);
      this.cache.set(key, entry);
      while (this.cache.size > this.MAX_CACHE_ENTRIES) {
        const oldest = this.cache.keys().next().value as string | undefined;
        if (!oldest) break;
        this.cache.delete(oldest);
      }
      return bundle;
    } finally {
      this.inFlight.delete(key);
    }
  }
}

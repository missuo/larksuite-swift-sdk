// Reference vectors produced by node-sdk itself (channel/ sources at
// /Users/missuo/Personal/node-sdk, transpiled with `tsc` (TypeScript 7) to
// CommonJS and executed with Node 26). Regenerate with the script below:
//
//   tsc -p tsconfig.json   # files: channel/normalize/index.ts, outbound/**/*.ts
//   node gen.js > vectors.json
//
// Nothing here is hand-written: every expected value is node-sdk output.
//
// gen.js:
/*
// Generates reference vectors from node-sdk's channel/ sources (transpiled
// with tsc into ./out). Usage: node gen.js > vectors.json
const path = require('path');
const out = path.join(__dirname, 'out/channel');
const dns = require('dns');

const utils = require(out + '/normalize/utils.js');
const registry = require(out + '/normalize/registry.js');
const normalizeMod = require(out + '/normalize/index.js');
const mentions = require(out + '/normalize/mentions.js');
const toPost = require(out + '/outbound/markdown/to-post.js');
const optimize = require(out + '/outbound/markdown/optimize-style.js');
const splitter = require(out + '/outbound/markdown/splitter.js');
const compose = require(out + '/outbound/markdown/compose-mentions.js');
const merge = require(out + '/outbound/streaming/merge-text.js');
const ogg = require(out + '/outbound/media/duration-ogg.js');
const mp4 = require(out + '/outbound/media/duration-mp4.js');
const ssrf = require(out + '/outbound/media/ssrf-guard.js');
const { OutboundSender } = require(out + '/outbound/sender.js');
const { MarkdownStreamControllerImpl } = require(out + '/outbound/streaming/markdown-stream.js');

const V = {};

// ── utils ──────────────────────────────────────────────────────────────
V.formatDuration = [0, 1, 499.5, 500, 999, 999.4, 999.5, 1000, 1250, 1450, 1500, 1750, 2050, 2250, 30000, 61234, 123456789, -1]
  .map((ms) => [ms, utils.formatDuration(ms) ?? null]);
V.millisToDatetime = ['1700000000000', 1700000000000, '0', 'abc', '1700000000000abc', 1, 4102444800000, '  42', 1.5e12, '-5', 951782400000, 1709164800000]
  .map((ms) => [ms, utils.millisToDatetime(ms) ?? null]);
V.rfc3339 = [1776753549563, 1, 86399999, 1709164800000].map((ms) => [ms, utils.formatRFC3339Beijing(ms)]);

// ── converters ─────────────────────────────────────────────────────────
const emptyCtx = () => ({ messageId: 'om_x', mentions: new Map(), mentionsByOpenId: new Map(), stripBotMentions: true, dispatch: registry.dispatchConvert });
const converterCases = [
  ['text', '{"text":"hello"}'], ['text', '{}'], ['text', 'nope'], ['text', '{"text":42}'],
  ['image', '{"image_key":"img_v3_abc"}'], ['image', '{}'],
  ['file', '{"file_key":"f1","file_name":"doc \\"q\\".pdf"}'], ['file', '{"file_key":"f1"}'], ['file', '{}'],
  ['audio', '{"file_key":"a1","duration":1500}'], ['audio', '{"file_key":"a1","duration":1000}'], ['audio', '{"file_key":"a1","duration":800}'], ['audio', '{"file_key":"a1"}'], ['audio', '{"file_key":"a1","duration":"1500"}'], ['audio', '{}'],
  ['video', '{"file_key":"v1","file_name":"clip.mp4","duration":30000,"image_key":"img_c"}'], ['media', '{"file_key":"v2","duration":1250}'], ['video', '{}'],
  ['sticker', '{"file_key":"s1"}'], ['sticker', '{}'],
  ['location', '{"name":"Cafe \\"A\\"","latitude":"39.9","longitude":"116.4"}'], ['location', '{"name":"X"}'], ['location', '{}'],
  ['share_chat', '{"chat_id":"oc_abc"}'], ['share_chat', '{}'], ['share_user', '{"user_id":"ou_bob"}'],
  ['system', '{"template":"{from_user} invited {to_chatters} to the group","from_user":["Alice"],"to_chatters":["Bob","Carol"]}'],
  ['system', '{"template":"{divider_text}","divider_text":"New messages"}'], ['system', '{"template":"{missing} x {count}","count":3}'],
  ['system', '{"template":"   "}'], ['system', '{}'], ['system', '{"template":"{constructor} {__proto__}"}'],
  ['vote', '{"topic":"Lunch?","options":["Noodles","Rice"]}'], ['vote', '{"options":["A"]}'], ['vote', '{}'],
  ['todo', '{"summary":{"title":"Ship it","content":[[{"tag":"text","text":"do "},{"tag":"a","text":"this","href":"https://x"}],[{"tag":"at","user_id":"ou_1"}]]},"due_time":"1700000000000"}'],
  ['todo', '{"summary":{}}'], ['todo', '{}'], ['todo', '{"summary":{"content":{"a":1}}}'],
  ['calendar', '{"summary":"Standup","start_time":"1700000000000","end_time":"1700001800000"}'], ['general_calendar', '{"summary":"S","start_time":1700000000000}'], ['share_calendar_event', '{}'], ['calendar', 'bad'],
  ['folder', '{"file_key":"fd1","file_name":"Docs"}'], ['folder', '{}'],
  ['hongbao', '{"text":"Happy \\"NY\\""}'], ['hongbao', '{}'],
  ['video_chat', '{"topic":"Weekly","start_time":"1700000000000"}'], ['video_chat', '{}'], ['video_chat', 'x'],
  ['interactive', JSON.stringify({ header: { title: { tag: 'plain_text', content: 'Approval' } }, elements: [{ tag: 'div', text: { tag: 'lark_md', content: '**body**' }, fields: [{ text: { tag: 'lark_md', content: 'f1' } }] }, { tag: 'action', actions: [{ tag: 'button', text: { tag: 'plain_text', content: 'OK' } }, { tag: 'select_static', placeholder: { tag: 'plain_text', content: 'Pick' }, options: [{ text: { tag: 'plain_text', content: 'One' } }, 'junk'] }] }, { tag: 'column_set', columns: [{ elements: [{ tag: 'markdown', content: 'col' }, { tag: 'markdown', content: 'col' }] }] }, { tag: 'input', label: { tag: 'plain_text', content: 'Name' } }] })],
  ['interactive', JSON.stringify({ schema: '2.0', body: { elements: [{ tag: 'markdown', content: '  ' }, { tag: 'markdown', content: 'v2 body' }] } })],
  ['interactive', '{}'], ['interactive', '"str"'],
  ['post', JSON.stringify({ zh_cn: { title: 'Hello', content: [[{ tag: 'text', text: 'world', style: ['bold', 'italic', 'underline', 'lineThrough', 'codeInline'] }], [{ tag: 'a', text: 'click', href: 'https://x.com' }, { tag: 'a', href: 'https://y.com' }, { tag: 'a', text: 'nolink' }], [{ tag: 'at', user_id: 'all' }, { tag: 'at', user_id: 'ou_unknown', user_name: 'Zed' }, { tag: 'at', user_id: 'ou_nobody' }], [{ tag: 'img', image_key: 'img_1' }, { tag: 'media', file_key: 'file_9' }, { tag: 'img' }], [{ tag: 'code_block', language: 'ts', text: 'let x = 1' }], [{ tag: 'hr' }], [{ tag: 'emotion', text: ':)' }, { tag: 'unknown' }]] } })],
  ['post', JSON.stringify({ en_us: { content: [[{ tag: 'text', text: 'english' }]] }, ja_jp: { content: [[{ tag: 'text', text: 'jp' }]] } })],
  ['post', JSON.stringify({ ko_kr: { content: [[{ tag: 'text', text: 'korean' }]] }, fr_fr: { content: [[{ tag: 'text', text: 'french' }]] } })],
  ['post', JSON.stringify({ title: '', content: [[{ tag: 'text', text: 'flat' }], 'notarray'] })],
  ['post', JSON.stringify({ zh_cn: { content: [[null]] } })], ['post', JSON.stringify({ zh_cn: { content: 5 } })],
  ['post', JSON.stringify([{ content: [[{ tag: 'text', text: 'array body' }]] }])],
  ['post', '{"zh_cn":{"content":[]}}'], ['post', 'not json'], ['post', '"s"'],
  ['merge_forward', '{}'],
  ['unknown_type', '{"text":"fallback body"}'], ['unknown_type', '{"random":"data"}'], ['unknown_type', 'not-json'],
];

async function main() {
  V.converters = [];
  for (const [type, raw] of converterCases) {
    const r = await registry.dispatchConvert(raw, type, emptyCtx());
    V.converters.push({ type, raw, content: r.content, resources: r.resources });
  }

  // ── normalize end-to-end ───────────────────────────────────────────
  const bot = { openId: 'ou_bot', name: 'TestBot' };
  const ev = (message, sender) => ({ sender: sender ?? { sender_id: { open_id: 'ou_alice', user_id: 'u_alice' } }, message: { message_id: 'om_x', chat_id: 'oc_test', chat_type: 'group', message_type: 'text', content: '{"text":"hello"}', create_time: '1700000000000', ...message } });
  const forwardItems = [
    { message_id: 'om_fw', msg_type: 'merge_forward', body: { content: 'Merged and Forwarded Message' }, sender: { id: 'ou_fwd' }, create_time: '1776849870916' },
    { message_id: 'om_c2', upper_message_id: 'om_fw', msg_type: 'text', body: { content: JSON.stringify({ text: 'second' }) }, sender: { id: 'ou_bob' }, create_time: '1776753669281' },
    { message_id: 'om_c1', upper_message_id: 'om_fw', msg_type: 'text', body: { content: JSON.stringify({ text: 'first\nline2' }) }, sender: { id: 'ou_alice' }, create_time: '1776753549563' },
    { message_id: 'om_nested', upper_message_id: 'om_fw', msg_type: 'merge_forward', body: { content: '' }, sender: { id: 'ou_carol' }, create_time: '1776753700000' },
    { message_id: 'om_n1', upper_message_id: 'om_nested', msg_type: 'image', body: { content: '{"image_key":"img_n"}' }, sender: { id: 'ou_dan' } },
    { message_id: 'om_c3', upper_message_id: 'om_fw', msg_type: 'post', body: { content: JSON.stringify({ zh_cn: { content: [[{ tag: 'text', text: 'p' }]] } }) }, create_time: 1776753800000 },
  ];
  const normCases = [
    ['basic', ev({}), {}],
    ['fallbackSender', ev({}, { sender_id: { union_id: 'on_x' } }), {}],
    ['mentions', ev({ content: '{"text":"@_user_1 please ask @_user_10 and @_bot"}', mentions: [{ key: '@_user_1', id: { open_id: 'ou_bob' }, name: 'Bob' }, { key: '@_user_10', id: { open_id: 'ou_ten', user_id: 'u_ten' }, name: 'Ten' }, { key: '@_bot', id: { open_id: 'ou_bot' }, name: 'TestBot' }] }), {}],
    ['mentionsNoStrip', ev({ content: '{"text":"@_bot  help\\tme  now"}', mentions: [{ key: '@_bot', id: { open_id: 'ou_bot' }, name: 'TestBot' }] }), { stripBotMentions: false }],
    ['botStripSpaces', ev({ content: '{"text":"hey @_bot   there"}', mentions: [{ key: '@_bot', id: { open_id: 'ou_bot' }, name: 'TestBot' }] }), {}],
    ['mentionAllArray', ev({ content: '{"text":"@_all listen"}', mentions: [{ key: '@_all', id: {}, name: '所有人' }] }), {}],
    ['mentionAllContent', ev({ content: '{"text":"@_all  hi"}' }), {}],
    ['mentionAllUnicode', ev({ content: '{"text":"@_all中文"}' }), {}],
    ['mentionAllied', ev({ content: '{"text":"@_allies"}' }), {}],
    ['postMention', ev({ message_type: 'post', content: JSON.stringify({ zh_cn: { title: 'Greeting', content: [[{ tag: 'text', text: 'hi ' }, { tag: 'at', user_id: 'ou_bob', user_name: 'Bob' }], [{ tag: 'img', image_key: 'img_1' }]] } }), mentions: [{ key: '@_user_1', id: { open_id: 'ou_bob' }, name: 'Bob' }] }), {}],
    ['noName', ev({ content: '{"text":"@_user_1 hi"}', mentions: [{ key: '@_user_1', id: { open_id: 'ou_x' } }] }), {}],
    ['thread', ev({ root_id: 'om_root', parent_id: 'om_parent', thread_id: 'omt_1', chat_type: 'p2p' }), {}],
    ['badCreate', ev({ create_time: 'abc' }), {}],
    ['noCreate', ev({ create_time: undefined }), {}],
    ['mergeForward', ev({ message_id: 'om_fw', message_type: 'merge_forward', content: '{}' }), { forward: true }],
    ['senderName', ev({}), { senderName: true }],
  ];
  V.normalize = [];
  for (const [name, event, o] of normCases) {
    const opts = { botIdentity: bot };
    if (o.stripBotMentions === false) opts.stripBotMentions = false;
    if (o.forward) {
      opts.fetchSubMessages = async () => forwardItems;
      opts.resolveUserName = (id) => (id === 'ou_alice' ? 'Alice' : undefined);
    }
    if (o.senderName) opts.resolveSenderName = (id) => (id === 'ou_alice' ? 'Alice' : undefined);
    const m = await normalizeMod.normalize(JSON.parse(JSON.stringify(event)), opts);
    V.normalize.push({ name, event, options: o, result: m });
  }
  V.forwardItems = forwardItems;

  // ── event normalizers ───────────────────────────────────────────────
  V.eventNormalizers = {
    cardAction: [
      { context: { open_message_id: 'om_1', open_chat_id: 'oc_1' }, operator: { open_id: 'ou_a', user_id: 'u_a', name: 'A' }, action: { value: { k: 'v' }, tag: 'button', name: 'n', option: 'o' } },
      { open_message_id: 'om_t', open_chat_id: 'oc_t', operator: { open_id: 'ou_a' }, action: {} },
      { context: { open_message_id: '', open_chat_id: 'oc_1' }, open_message_id: 'om_top', operator: { open_id: 'ou_a' } },
      { context: { open_chat_id: 'oc_1' }, open_message_id: 'om_top', operator: { open_id: 'ou_a' }, action: { value: null, tag: 'select' } },
    ].map((e) => [e, normalizeMod.normalizeCardAction(e) ?? null]),
    reaction: [
      { message_id: 'om_1', reaction_type: { emoji_type: 'OK' }, user_id: { open_id: 'ou_a', user_id: null }, action_time: '1000000000000' },
      { message_id: 'om_1', reaction_type: { emoji_type: 'OK' }, user_id: { open_id: 'ou_a', user_id: 'u_a' }, action_time: 'x' },
      { message_id: 'om_1', reaction_type: { emoji_type: '' }, user_id: { open_id: 'ou_a' } },
    ].map((e) => [e, normalizeMod.normalizeReaction(e, 'added') ?? null]),
    botAdded: [
      { chat_id: 'oc_1', operator_id: { open_id: 'ou_a', user_id: null }, i18n_names: { ja_jp: 'JP' }, external: false },
      { chat_id: 'oc_1', operator_id: { open_id: 'ou_a' }, name: '', i18n_names: { zh_cn: 'ZH' } },
      { chat_id: 'oc_1', operator_id: {} },
    ].map((e) => [e, normalizeMod.normalizeBotAdded(e) ?? null]),
    comment: [
      { comment_id: 'c1', is_mentioned: false, create_time: '1776838695000', notice_meta: { file_token: 'ft', file_type: 'docx', from_user_id: { open_id: 'ou_a', union_id: 'on_a', user_id: null }, is_mentioned: true } },
      { file_token: 'ft', file_type: 'sheet', comment_id: 'c2', notice_meta: { timestamp: '1700000000000', from_user_id: { open_id: 'ou_b' } }, is_mention: true },
      { file_token: 'ft', file_type: 'doc', comment_id: 'c3', user_id: { open_id: 'ou_c', user_id: 'u_c' }, action_time: '1700000000001' },
    ].map((e) => [e, normalizeMod.normalizeComment(e) ?? null]),
  };

  // ── mentions ────────────────────────────────────────────────────────
  V.resolveMentions = [
    ['hello @_user_1', [['@_user_1', { key: '@_user_1', openId: 'ou_a', name: 'Alice', isBot: false }]], true],
    ['@_bot help me', [['@_bot', { key: '@_bot', openId: 'ou_bot', name: 'Bot', isBot: true }]], true],
    ['@_bot help me', [['@_bot', { key: '@_bot', openId: 'ou_bot', name: 'Bot', isBot: true }]], false],
    ['a @_bot\n@_bot b', [['@_bot', { key: '@_bot', openId: 'ou_bot', name: 'Bot', isBot: true }]], true],
    ['x  y\t\tz', [['@_u', { key: '@_u', name: 'U', isBot: false }]], true],
    ['@_user_1 $& @_user_2', [['@_user_1', { key: '@_user_1', name: '$1', isBot: false }], ['@_user_2', { key: '@_user_2', name: '', isBot: false }]], true],
    ['  keep  ', [], true],
  ].map(([content, entries, strip]) => [content, entries, strip, mentions.resolveMentions(content, { mentions: new Map(entries), stripBotMentions: strip })]);

  // ── markdown ────────────────────────────────────────────────────────
  const mdInputs = [
    'hello world', '# Title\n\nbody', '# A\n\n## B\n\n### C\n\n#### D\n\n###### F', '#### existing H4', 'a\n\n\n\nb',
    '# heading\n\n```ts\n# not a heading inside code\n```', '```bash\necho $\'x\' $& $` done\n```\ntext',
    '## Sub\ntext\n### Third', 'text\n| a | b |\n|---|---|\n| 1 | 2 |\nafter', '#### H4\n#### H4b\n\n##### H5',
    '**bold**\n\n| t |\n| - |\ntrail', 'line\n```\ncode\n```\n```\nmore\n```', '````md\n```inner```\n````', 'x\r\n# y',
    'para\n\n| a |\n|---|\n\n---\nend', '| only | table |\n|---|---|', '#Not heading\n# Real',
  ];
  V.markdownToPost = mdInputs.map((md) => [md, JSON.stringify(toPost.markdownToPost(md))]);
  V.markdownToPostMentions = JSON.stringify(toPost.markdownToPost('hi', { mentions: [{ key: '@_user_1', openId: 'ou_a', name: 'Alice' }, { key: '@_x', name: 'NoId' }, { key: '@_user_2', openId: 'ou_b' }], title: 'T' }));
  V.optimizeV2 = mdInputs.map((md) => [md, optimize.optimizeMarkdownStyle(md, 2)]);
  const longFence = '```ts\n' + 'x'.repeat(60) + '\n' + 'y'.repeat(60) + '\n```';
  V.split = [
    ['hello', 100], ['', 100], [Array(20).fill('aaaaaaaa').join('\n'), 30], [longFence, 40], ['```python\n' + 'a'.repeat(100) + '\n```', 40],
    ['a'.repeat(30) + '\n## Heading\nafter', 40], ['one\ntwo\n```\ncode1\ncode2\ncode3\n```\nthree\n# H\nfour', 15], ['x'.repeat(50), 10],
    ['中文'.repeat(20) + '\n' + '😀'.repeat(10), 30],
  ].map(([t, l]) => [t, l, splitter.splitWithCodeFences(t, l)]);
  V.merge = [['', 'hello'], ['hello', ''], ['hello', 'hello world'], ['hello world', 'hello'], ['hello wor', 'world foo'], ['abc', 'xyz'], ['foo', 'oo bar'], ['aaa', 'aab'], ['ab', 'ba']]
    .map(([a, b]) => [a, b, merge.mergeStreamingText(a, b)]);
  V.postToPlainText = [
    toPost.markdownToPost('hello **world** [link](https://x)'),
    { zh_cn: { content: [[{ tag: 'text', text: 'hello ' }, { tag: 'at', user_name: 'Alice' }, { tag: 'text', text: ' see ' }, { tag: 'a', text: 'docs', href: 'https://x' }, { tag: 'img', image_key: 'img_1' }], [{ tag: 'at' }, { tag: 'img' }, { tag: 'hr' }], 'skip', [{ tag: 'md', text: '  tail  ' }]] } },
    { en_us: { content: [[{ tag: 'text', text: 'x' }]] } }, null, {},
  ].map((p) => [p, toPost.postToPlainText(p)]);
  V.composeText = compose.composeMentionsTextPrefix([{ key: '@_a', openId: 'ou_a', name: 'A' }, { key: '@_b', openId: 'ou_b' }, { key: '@_c', name: 'C' }]);

  // ── durations ───────────────────────────────────────────────────────
  function oggPage(granule) {
    const b = Buffer.alloc(27); b.write('OggS', 0, 'ascii'); b.writeBigInt64LE(granule, 6); b.writeUInt32LE(1, 14); return b;
  }
  function box(type, payload) {
    const b = Buffer.alloc(8 + payload.length); b.writeUInt32BE(8 + payload.length, 0); b.write(type, 4, 'ascii'); payload.copy(b, 8); return b;
  }
  function mvhd0(ts, dur) { const p = Buffer.alloc(100); p.writeUInt32BE(ts, 12); p.writeUInt32BE(dur, 16); return box('mvhd', p); }
  function mvhd1(ts, dur) { const p = Buffer.alloc(112); p.writeUInt8(1, 0); p.writeUInt32BE(ts, 20); p.writeBigUInt64BE(dur, 24); return box('mvhd', p); }
  const ftyp = box('ftyp', Buffer.from('isom\0\0\0\0isomavc1'));
  const large = (() => { const inner = mvhd0(1000, 4321); const b = Buffer.alloc(16 + inner.length); b.writeUInt32BE(1, 0); b.write('moov', 4, 'ascii'); b.writeBigUInt64BE(BigInt(16 + inner.length), 8); inner.copy(b, 16); return b; })();
  const zeroSize = (() => { const inner = mvhd0(90000, 900000); const b = Buffer.alloc(8 + inner.length); b.writeUInt32BE(0, 0); b.write('moov', 4, 'ascii'); inner.copy(b, 8); return b; })();
  const oggCases = [
    Buffer.concat([Buffer.from('junk'), oggPage(24000n), Buffer.from([1, 2, 3]), oggPage(96000n), Buffer.alloc(5)]),
    oggPage(48000n), oggPage(72024n), oggPage(-1n), Buffer.alloc(10), Buffer.from('not an ogg file here at all at all'), oggPage(47n),
  ];
  V.ogg = oggCases.map((b) => [b.toString('hex'), ogg.parseOpusDuration(b) ?? null]);
  const mp4Cases = [
    box('moov', mvhd0(1000, 30000)), Buffer.concat([ftyp, box('moov', Buffer.concat([box('trak', Buffer.alloc(4)), mvhd0(600, 3601)]))]),
    box('moov', mvhd1(48000, 480000000n)), large, Buffer.concat([ftyp, zeroSize]), box('moov', mvhd0(0, 10)),
    Buffer.concat([box('mdat', Buffer.alloc(20)), box('moov', mvhd0(1000, 999))]), (() => { const b = Buffer.alloc(100); b.write('mdat', 4); return b; })(),
    Buffer.from('this is not an mp4 file at all really nothing to see here'), (() => { const m = box('moov', mvhd0(1000, 5)); m.writeUInt32BE(9999, 0); return m; })(),
  ];
  V.mp4 = mp4Cases.map((b) => { let r; try { r = mp4.parseMp4Duration(b) ?? null; } catch (e) { r = 'throws'; } return [b.toString('hex'), r]; });

  // ── SSRF guard ──────────────────────────────────────────────────────
  const ssrfCases = [
    ['https://example.com/x', [{ address: '8.8.8.8', family: 4 }]], ['http://evil.com/', [{ address: '169.254.169.254', family: 4 }]],
    ['http://evil.com/', [{ address: '8.8.8.8', family: 4 }, { address: '169.254.169.254', family: 4 }]], ['http://1.2.3.4/', null],
    ['http://169.254.169.254/', null], ['http://[::1]/', null], ['http://[::ffff:127.0.0.1]/', null], ['http://[::ffff:8.8.8.8]:8080/p', null],
    ['http://[2001:4860:4860:0:0:0:0:8888]/', null], ['HTTP://Example.COM/', [{ address: '93.184.216.34', family: 4 }]],
    ['http://2130706433/', null], ['http://0x7f.1/', null], ['http://010.0.0.1/', null], ['http://8.8.8.8./', null],
    ['http://exp.test/', [{ address: '0:0:0:0:0:ffff:7f00:1', family: 6 }]], ['http://c.test/', [{ address: '::7f00:1', family: 6 }]],
    ['http://n.test/', [{ address: '64:ff9b::a00:1', family: 6 }]], ['http://n.test/', [{ address: '64:ff9b::808:808', family: 6 }]],
    ['http://d.test/', [{ address: '2001:db8::1', family: 6 }]], ['http://t.test/', [{ address: '2001:0:1234::1', family: 6 }]],
    ['http://g.test/', [{ address: '2001:4860:4860::8888', family: 6 }]], ['http://l.test/', [{ address: 'fe80::1%eth0', family: 6 }]],
    ['http://u.test/', [{ address: 'fc12:3456::1', family: 6 }]], ['http://u.test/', [{ address: 'fd00:abcd::1', family: 6 }]],
    ['http://lo.test/', [{ address: '0:0:0:0:0:0:0:1', family: 6 }]], ['http://bad.test/', [{ address: 'not::an::ipv6', family: 6 }]],
    ['http://m.test/', [{ address: 'ff02::1', family: 6 }]], ['http://dz.test/', [{ address: '100::1', family: 6 }]],
    ['http://dz.test/', [{ address: '100:0:0:1::1', family: 6 }]], ['http://m4.test/', [{ address: '::ffff:10.1.2.3', family: 6 }]],
    ['file:///etc/passwd', null], ['gopher://evil.com/', null], ['http://nx.invalid/', []],
    ['http://internal.corp/', [{ address: '10.0.0.1', family: 4 }], ['internal.corp']], ['http://100.64.0.1/', null], ['http://100.128.0.1/', null],
    ['http://p.test/', [{ address: '8.8.8.8', family: 4 }, { address: '1.1.1.1', family: 4 }]], ['http://172.15.255.255/', null], ['http://172.16.0.1/', null],
    ['http://192.0.2.5/', null], ['http://198.19.1.1/', null], ['http://198.20.1.1/', null], ['http://224.0.0.1/', null], ['http://255.255.255.255/', null],
    ['http://user:pw@8.8.4.4:99/x?y#z', null], ['https://[fe80::1]/', null],
  ];
  V.ssrf = [];
  for (const [url, records, allowlist] of ssrfCases) {
    dns.promises.lookup = async () => records ?? [];
    let r;
    try { const v = await ssrf.assertPublicUrl(url, allowlist ? { allowlist } : {}); r = { ok: v }; } catch (e) { r = { error: e.message }; }
    V.ssrf.push({ url, records, allowlist: allowlist ?? null, result: r });
  }
  V.hostnames = ['http://[0:0:0:0:0:0:0:1]/', 'http://[::FFFF:127.0.0.1]/', 'http://[1:0:0:2:0:0:0:3]/', 'http://[1:0:0:0:2:0:0:3]/', 'http://[0:1:0:1:0:1:0:1]/', 'http://0x7f000001/', 'http://0177.0.0.1/', 'http://1.2.3/', 'http://Foo.Example.com:80/']
    .map((u) => [u, new URL(u).hostname]);

  // ── outbound wire ───────────────────────────────────────────────────
  V.wire = {};
  function fakeClient(log, opts = {}) {
    let mid = 0, cid = 0;
    const fails = opts.fails ?? {};
    const rec = (name, http) => async (args) => {
      const d = args.data ?? {};
      const entry = { api: name, method: http.method, path: http.path(args.path ?? {}), query: args.params ?? null };
      if (http.multipart) entry.form = Object.fromEntries(Object.entries(d).map(([k, v]) => [k, Buffer.isBuffer(v) ? { hex: v.toString('hex') } : v]));
      else if (args.data !== undefined) entry.body = JSON.stringify(d);
      log.push(entry);
      if (fails[name] && fails[name].length) throw fails[name].shift();
      return http.res();
    };
    const okMsg = () => ({ code: 0, data: { message_id: `om_${++mid}` } });
    return {
      im: { v1: {
        message: {
          create: rec('message.create', { method: 'POST', path: () => '/open-apis/im/v1/messages', res: okMsg }),
          reply: rec('message.reply', { method: 'POST', path: (p) => `/open-apis/im/v1/messages/${p.message_id}/reply`, res: okMsg }),
          patch: rec('message.patch', { method: 'PATCH', path: (p) => `/open-apis/im/v1/messages/${p.message_id}`, res: () => ({ code: 0 }) }),
        },
        image: { create: rec('image.create', { method: 'POST', path: () => '/open-apis/im/v1/images', multipart: true, res: () => ({ image_key: 'img_up' }) }) },
        file: { create: rec('file.create', { method: 'POST', path: () => '/open-apis/im/v1/files', multipart: true, res: () => ({ file_key: 'file_up' }) }) },
      } },
      cardkit: { v1: {
        card: {
          create: rec('card.create', { method: 'POST', path: () => '/open-apis/cardkit/v1/cards', res: () => ({ code: 0, data: { card_id: `card_${++cid}` } }) }),
          settings: rec('card.settings', { method: 'PATCH', path: (p) => `/open-apis/cardkit/v1/cards/${p.card_id}/settings`, res: () => ({ code: 0 }) }),
        },
        cardElement: { content: rec('cardElement.content', { method: 'PUT', path: (p) => `/open-apis/cardkit/v1/cards/${p.card_id}/elements/${p.element_id}/content`, res: () => ({ code: 0 }) }) },
      } },
    };
  }
  const logger = { info() {}, warn() {}, error() {}, debug() {}, trace() {} };
  const apiErr = (code, status) => { const e = new Error(`feishu error ${code}`); e.response = { status, data: { code, msg: `code ${code}` } }; return e; };
  const big = { streamThrottleMs: 1e9, streamThrottleChars: 1e9 };
  const scenarios = {
    text: (s) => s.send('oc_chat', { text: 'hello "world"\n/slash 中文 😀' }),
    textMentionsReply: (s) => s.send('ou_user', { text: 'hi' }, { replyTo: 'om_parent', replyInThread: true, mentions: [{ key: '@_user_1', openId: 'ou_a', name: 'A' }, { key: '@_x', name: 'X' }] }),
    textChunks: (s) => s.send('on_union', { text: 'abcdefghijklmnopqrstuvwxy' }, { replyTo: 'om_r' }),
    markdown: (s) => s.send('oc_chat', { markdown: '# Title\n\nbody **bold** `code`\n\n\n\nend' }, { mentions: [{ key: '@_user_1', openId: 'ou_a', name: 'Alice' }] }),
    markdownChunks: (s) => s.send('alice@example.com', { markdown: 'para one line\npara two line\n```js\nconst a = 1;\nconst b = 2;\n```\n## Next\nmore text here' }, { replyTo: 'om_r', mentions: [{ key: '@_user_1', openId: 'ou_a', name: 'Alice' }] }),
    post: (s) => s.send('oc_chat', { post: { zh_cn: { content: [[{ tag: 'text', text: 'x' }]], title: 't' } } }),
    card: (s) => s.send('oc_chat', { card: { body: { elements: [{ content: 'hi', tag: 'markdown' }] }, schema: '2.0' } }, { replyTo: 'om_r', replyInThread: false }),
    shareChat: (s) => s.send('oc_chat', { shareChat: { chatId: 'oc_target' } }),
    shareUser: (s) => s.send('oc_chat', { shareUser: { userId: 'ou_alice' } }),
    sticker: (s) => s.send('u_plain', { sticker: { fileKey: 'sticker_abc' } }),
    image: (s) => s.send('oc_chat', { image: { source: Buffer.from([1, 2, 3]) } }),
    file: (s) => s.send('oc_chat', { file: { source: Buffer.from('doc'), fileName: 'a.txt' } }),
    audio: (s) => s.send('oc_chat', { audio: { source: Buffer.from('opus'), duration: 3000 } }),
    video: (s) => s.send('oc_chat', { video: { source: Buffer.from('mp4'), duration: 5000, coverImageKey: 'img_cover' } }),
    postFallback: [(s) => s.send('oc_chat', { post: { zh_cn: { content: [[{ tag: 'text', text: 'hello' }, { tag: 'at', user_name: 'Al' }]], title: 'bad' } } }), { 'message.create': [apiErr(230002, 400)] }],
    markdownFallbackEmpty: [(s) => s.send('oc_chat', { markdown: '' }), { 'message.create': [apiErr(230001, 200)] }],
    replyRevoked: [(s) => s.send('oc_chat', { text: 'hi' }, { replyTo: 'om_gone' }), { 'message.reply': [apiErr(230020, 404)] }],
    streamMarkdown: [async (s) => s.stream('oc_chat', { markdown: async (c) => { await c.append('Hello '); await c.append('Hello world'); await c.append(' and more   text\nnew line'); } }, { replyTo: 'om_r' }), {}, big],
    streamMarkdownEmpty: [async (s) => s.stream('oc_chat', { markdown: async () => {} }), {}, { ...big, streamInitialText: '' }],
    streamMarkdownSetContent: [async (s) => s.stream('oc_chat', { markdown: async (c) => { await c.append('a'); await c.setContent('replaced'); } }), {}, { ...big, streamInitialText: 'Wait' }],
    streamMarkdownRollover: [async (s) => s.stream('oc_chat', { markdown: async (c) => { await c.setContent('line one is here\nline two is here\nline three here\nfour'); } }), {}, { ...big, streamMaxElementChars: 20 }],
    streamMarkdownLongSummary: [async (s) => s.stream('oc_chat', { markdown: async (c) => { await c.append('x'.repeat(60)); } }), {}, big],
    streamCard: [async (s) => s.stream('oc_chat', { card: { initial: { elements: [{ content: 'v0', tag: 'markdown' }], schema: '2.0' }, producer: async (c) => { await c.update({ elements: [{ content: 'v1', tag: 'markdown' }], schema: '2.0' }); await c.update((cur) => ({ ...cur, header: { title: 'T' } })); } } }), {}, big],
  };
  for (const [name, def] of Object.entries(scenarios)) {
    const [fn, fails, cfg] = Array.isArray(def) ? def : [def, {}, {}];
    const log = [];
    const sender = new OutboundSender(fakeClient(log, { fails: { ...fails } }), { retry: { maxAttempts: 1, baseDelayMs: 0 }, textChunkLimit: name === 'textChunks' ? 10 : name === 'markdownChunks' ? 40 : undefined, ...cfg }, logger);
    let result, error;
    try { result = await fn(sender); } catch (e) { error = e.message; }
    V.wire[name] = { calls: log, result: result ?? null, error: error ?? null, config: cfg ?? {} };
  }
  // Producer failure (thrown error) for markdown + card streams.
  for (const [name, fn] of [
    ['streamMarkdownFail', (s) => s.stream('oc_chat', { markdown: async (c) => { await c.append('partial'); throw new Error('producer failure'); } })],
    ['streamCardFail', (s) => s.stream('oc_chat', { card: { initial: { elements: [{ tag: 'div' }] }, producer: async (c) => { await c.update({ header: { t: 1 } }); throw new Error('boom'); } } })],
  ]) {
    const log = [];
    const sender = new OutboundSender(fakeClient(log), { retry: { maxAttempts: 1, baseDelayMs: 0 }, ...big }, logger);
    let error;
    try { await fn(sender); } catch (e) { error = e.message; }
    V.wire[name] = { calls: log, result: null, error, config: big };
  }

  process.stdout.write(JSON.stringify(V, null, 1));
}
main().catch((e) => { console.error(e); process.exit(1); });
*/

enum NodeVectors {
    static let json = ##"""
{
 "formatDuration": [
  [
   0,
   "0ms"
  ],
  [
   1,
   "1ms"
  ],
  [
   499.5,
   "500ms"
  ],
  [
   500,
   "500ms"
  ],
  [
   999,
   "999ms"
  ],
  [
   999.4,
   "999ms"
  ],
  [
   999.5,
   "1000ms"
  ],
  [
   1000,
   "1s"
  ],
  [
   1250,
   "1.3s"
  ],
  [
   1450,
   "1.4s"
  ],
  [
   1500,
   "1.5s"
  ],
  [
   1750,
   "1.8s"
  ],
  [
   2050,
   "2.0s"
  ],
  [
   2250,
   "2.3s"
  ],
  [
   30000,
   "30s"
  ],
  [
   61234,
   "61.2s"
  ],
  [
   123456789,
   "123456.8s"
  ],
  [
   -1,
   null
  ]
 ],
 "millisToDatetime": [
  [
   "1700000000000",
   "2023-11-15 06:13"
  ],
  [
   1700000000000,
   "2023-11-15 06:13"
  ],
  [
   "0",
   null
  ],
  [
   "abc",
   null
  ],
  [
   "1700000000000abc",
   "2023-11-15 06:13"
  ],
  [
   1,
   "1970-01-01 08:00"
  ],
  [
   4102444800000,
   "2100-01-01 08:00"
  ],
  [
   "  42",
   "1970-01-01 08:00"
  ],
  [
   1500000000000,
   "2017-07-14 10:40"
  ],
  [
   "-5",
   null
  ],
  [
   951782400000,
   "2000-02-29 08:00"
  ],
  [
   1709164800000,
   "2024-02-29 08:00"
  ]
 ],
 "rfc3339": [
  [
   1776753549563,
   "2026-04-21T14:39:09+08:00"
  ],
  [
   1,
   "1970-01-01T08:00:00+08:00"
  ],
  [
   86399999,
   "1970-01-02T07:59:59+08:00"
  ],
  [
   1709164800000,
   "2024-02-29T08:00:00+08:00"
  ]
 ],
 "converters": [
  {
   "type": "text",
   "raw": "{\"text\":\"hello\"}",
   "content": "hello",
   "resources": []
  },
  {
   "type": "text",
   "raw": "{}",
   "content": "",
   "resources": []
  },
  {
   "type": "text",
   "raw": "nope",
   "content": "",
   "resources": []
  },
  {
   "type": "text",
   "raw": "{\"text\":42}",
   "content": 42,
   "resources": []
  },
  {
   "type": "image",
   "raw": "{\"image_key\":\"img_v3_abc\"}",
   "content": "![image](img_v3_abc)",
   "resources": [
    {
     "type": "image",
     "fileKey": "img_v3_abc"
    }
   ]
  },
  {
   "type": "image",
   "raw": "{}",
   "content": "[image]",
   "resources": []
  },
  {
   "type": "file",
   "raw": "{\"file_key\":\"f1\",\"file_name\":\"doc \\\"q\\\".pdf\"}",
   "content": "<file key=\"f1\" name=\"doc &quot;q&quot;.pdf\"/>",
   "resources": [
    {
     "type": "file",
     "fileKey": "f1",
     "fileName": "doc \"q\".pdf"
    }
   ]
  },
  {
   "type": "file",
   "raw": "{\"file_key\":\"f1\"}",
   "content": "<file key=\"f1\"/>",
   "resources": [
    {
     "type": "file",
     "fileKey": "f1"
    }
   ]
  },
  {
   "type": "file",
   "raw": "{}",
   "content": "[file]",
   "resources": []
  },
  {
   "type": "audio",
   "raw": "{\"file_key\":\"a1\",\"duration\":1500}",
   "content": "<audio key=\"a1\" duration=\"1.5s\"/>",
   "resources": [
    {
     "type": "audio",
     "fileKey": "a1",
     "durationMs": 1500
    }
   ]
  },
  {
   "type": "audio",
   "raw": "{\"file_key\":\"a1\",\"duration\":1000}",
   "content": "<audio key=\"a1\" duration=\"1s\"/>",
   "resources": [
    {
     "type": "audio",
     "fileKey": "a1",
     "durationMs": 1000
    }
   ]
  },
  {
   "type": "audio",
   "raw": "{\"file_key\":\"a1\",\"duration\":800}",
   "content": "<audio key=\"a1\" duration=\"800ms\"/>",
   "resources": [
    {
     "type": "audio",
     "fileKey": "a1",
     "durationMs": 800
    }
   ]
  },
  {
   "type": "audio",
   "raw": "{\"file_key\":\"a1\"}",
   "content": "<audio key=\"a1\"/>",
   "resources": [
    {
     "type": "audio",
     "fileKey": "a1"
    }
   ]
  },
  {
   "type": "audio",
   "raw": "{\"file_key\":\"a1\",\"duration\":\"1500\"}",
   "content": "<audio key=\"a1\"/>",
   "resources": [
    {
     "type": "audio",
     "fileKey": "a1",
     "durationMs": "1500"
    }
   ]
  },
  {
   "type": "audio",
   "raw": "{}",
   "content": "[audio]",
   "resources": []
  },
  {
   "type": "video",
   "raw": "{\"file_key\":\"v1\",\"file_name\":\"clip.mp4\",\"duration\":30000,\"image_key\":\"img_c\"}",
   "content": "<video key=\"v1\" name=\"clip.mp4\" duration=\"30s\"/>",
   "resources": [
    {
     "type": "video",
     "fileKey": "v1",
     "fileName": "clip.mp4",
     "durationMs": 30000,
     "coverImageKey": "img_c"
    }
   ]
  },
  {
   "type": "media",
   "raw": "{\"file_key\":\"v2\",\"duration\":1250}",
   "content": "<video key=\"v2\" duration=\"1.3s\"/>",
   "resources": [
    {
     "type": "video",
     "fileKey": "v2",
     "durationMs": 1250
    }
   ]
  },
  {
   "type": "video",
   "raw": "{}",
   "content": "[video]",
   "resources": []
  },
  {
   "type": "sticker",
   "raw": "{\"file_key\":\"s1\"}",
   "content": "<sticker key=\"s1\"/>",
   "resources": [
    {
     "type": "sticker",
     "fileKey": "s1"
    }
   ]
  },
  {
   "type": "sticker",
   "raw": "{}",
   "content": "[sticker]",
   "resources": []
  },
  {
   "type": "location",
   "raw": "{\"name\":\"Cafe \\\"A\\\"\",\"latitude\":\"39.9\",\"longitude\":\"116.4\"}",
   "content": "<location name=\"Cafe &quot;A&quot;\" coords=\"lat:39.9,lng:116.4\"/>",
   "resources": []
  },
  {
   "type": "location",
   "raw": "{\"name\":\"X\"}",
   "content": "<location name=\"X\"/>",
   "resources": []
  },
  {
   "type": "location",
   "raw": "{}",
   "content": "<location/>",
   "resources": []
  },
  {
   "type": "share_chat",
   "raw": "{\"chat_id\":\"oc_abc\"}",
   "content": "<group_card id=\"oc_abc\"/>",
   "resources": []
  },
  {
   "type": "share_chat",
   "raw": "{}",
   "content": "<group_card id=\"\"/>",
   "resources": []
  },
  {
   "type": "share_user",
   "raw": "{\"user_id\":\"ou_bob\"}",
   "content": "<contact_card id=\"ou_bob\"/>",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{\"template\":\"{from_user} invited {to_chatters} to the group\",\"from_user\":[\"Alice\"],\"to_chatters\":[\"Bob\",\"Carol\"]}",
   "content": "Alice invited Bob, Carol to the group",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{\"template\":\"{divider_text}\",\"divider_text\":\"New messages\"}",
   "content": "New messages",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{\"template\":\"{missing} x {count}\",\"count\":3}",
   "content": "x {count}",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{\"template\":\"   \"}",
   "content": "[system message]",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{}",
   "content": "[system message]",
   "resources": []
  },
  {
   "type": "system",
   "raw": "{\"template\":\"{constructor} {__proto__}\"}",
   "content": "{constructor} {__proto__}",
   "resources": []
  },
  {
   "type": "vote",
   "raw": "{\"topic\":\"Lunch?\",\"options\":[\"Noodles\",\"Rice\"]}",
   "content": "<vote>\nLunch?\n• Noodles\n• Rice\n</vote>",
   "resources": []
  },
  {
   "type": "vote",
   "raw": "{\"options\":[\"A\"]}",
   "content": "<vote>\n• A\n</vote>",
   "resources": []
  },
  {
   "type": "vote",
   "raw": "{}",
   "content": "<vote>\n[vote]\n</vote>",
   "resources": []
  },
  {
   "type": "todo",
   "raw": "{\"summary\":{\"title\":\"Ship it\",\"content\":[[{\"tag\":\"text\",\"text\":\"do \"},{\"tag\":\"a\",\"text\":\"this\",\"href\":\"https://x\"}],[{\"tag\":\"at\",\"user_id\":\"ou_1\"}]]},\"due_time\":\"1700000000000\"}",
   "content": "<todo>\nShip it\ndo this\nDue: 2023-11-15 06:13\n</todo>",
   "resources": []
  },
  {
   "type": "todo",
   "raw": "{\"summary\":{}}",
   "content": "<todo>\n[todo]\n</todo>",
   "resources": []
  },
  {
   "type": "todo",
   "raw": "{}",
   "content": "<todo>\n[todo]\n</todo>",
   "resources": []
  },
  {
   "type": "todo",
   "raw": "{\"summary\":{\"content\":{\"a\":1}}}",
   "content": "[unsupported message]",
   "resources": []
  },
  {
   "type": "calendar",
   "raw": "{\"summary\":\"Standup\",\"start_time\":\"1700000000000\",\"end_time\":\"1700001800000\"}",
   "content": "<calendar_invite>\n📅 Standup\n🕙 2023-11-15 06:13 ~ 2023-11-15 06:43\n</calendar_invite>",
   "resources": []
  },
  {
   "type": "general_calendar",
   "raw": "{\"summary\":\"S\",\"start_time\":1700000000000}",
   "content": "<calendar>\n📅 S\n🕙 2023-11-15 06:13\n</calendar>",
   "resources": []
  },
  {
   "type": "share_calendar_event",
   "raw": "{}",
   "content": "<calendar_share>\n[calendar event]\n</calendar_share>",
   "resources": []
  },
  {
   "type": "calendar",
   "raw": "bad",
   "content": "<calendar_invite>\n[calendar event]\n</calendar_invite>",
   "resources": []
  },
  {
   "type": "folder",
   "raw": "{\"file_key\":\"fd1\",\"file_name\":\"Docs\"}",
   "content": "<folder key=\"fd1\" name=\"Docs\"/>",
   "resources": []
  },
  {
   "type": "folder",
   "raw": "{}",
   "content": "[folder]",
   "resources": []
  },
  {
   "type": "hongbao",
   "raw": "{\"text\":\"Happy \\\"NY\\\"\"}",
   "content": "<hongbao text=\"Happy &quot;NY&quot;\"/>",
   "resources": []
  },
  {
   "type": "hongbao",
   "raw": "{}",
   "content": "<hongbao/>",
   "resources": []
  },
  {
   "type": "video_chat",
   "raw": "{\"topic\":\"Weekly\",\"start_time\":\"1700000000000\"}",
   "content": "<meeting>\n📹 Weekly\n🕙 2023-11-15 06:13\n</meeting>",
   "resources": []
  },
  {
   "type": "video_chat",
   "raw": "{}",
   "content": "<meeting>\n[video chat]\n</meeting>",
   "resources": []
  },
  {
   "type": "video_chat",
   "raw": "x",
   "content": "<meeting>\n[video chat]\n</meeting>",
   "resources": []
  },
  {
   "type": "interactive",
   "raw": "{\"header\":{\"title\":{\"tag\":\"plain_text\",\"content\":\"Approval\"}},\"elements\":[{\"tag\":\"div\",\"text\":{\"tag\":\"lark_md\",\"content\":\"**body**\"},\"fields\":[{\"text\":{\"tag\":\"lark_md\",\"content\":\"f1\"}}]},{\"tag\":\"action\",\"actions\":[{\"tag\":\"button\",\"text\":{\"tag\":\"plain_text\",\"content\":\"OK\"}},{\"tag\":\"select_static\",\"placeholder\":{\"tag\":\"plain_text\",\"content\":\"Pick\"},\"options\":[{\"text\":{\"tag\":\"plain_text\",\"content\":\"One\"}},\"junk\"]}]},{\"tag\":\"column_set\",\"columns\":[{\"elements\":[{\"tag\":\"markdown\",\"content\":\"col\"},{\"tag\":\"markdown\",\"content\":\"col\"}]}]},{\"tag\":\"input\",\"label\":{\"tag\":\"plain_text\",\"content\":\"Name\"}}]}",
   "content": "Approval\n**body**\nf1\nOK\nPick\nOne\ncol\nName",
   "resources": []
  },
  {
   "type": "interactive",
   "raw": "{\"schema\":\"2.0\",\"body\":{\"elements\":[{\"tag\":\"markdown\",\"content\":\"  \"},{\"tag\":\"markdown\",\"content\":\"v2 body\"}]}}",
   "content": "v2 body",
   "resources": []
  },
  {
   "type": "interactive",
   "raw": "{}",
   "content": "[interactive card]",
   "resources": []
  },
  {
   "type": "interactive",
   "raw": "\"str\"",
   "content": "[interactive card]",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"zh_cn\":{\"title\":\"Hello\",\"content\":[[{\"tag\":\"text\",\"text\":\"world\",\"style\":[\"bold\",\"italic\",\"underline\",\"lineThrough\",\"codeInline\"]}],[{\"tag\":\"a\",\"text\":\"click\",\"href\":\"https://x.com\"},{\"tag\":\"a\",\"href\":\"https://y.com\"},{\"tag\":\"a\",\"text\":\"nolink\"}],[{\"tag\":\"at\",\"user_id\":\"all\"},{\"tag\":\"at\",\"user_id\":\"ou_unknown\",\"user_name\":\"Zed\"},{\"tag\":\"at\",\"user_id\":\"ou_nobody\"}],[{\"tag\":\"img\",\"image_key\":\"img_1\"},{\"tag\":\"media\",\"file_key\":\"file_9\"},{\"tag\":\"img\"}],[{\"tag\":\"code_block\",\"language\":\"ts\",\"text\":\"let x = 1\"}],[{\"tag\":\"hr\"}],[{\"tag\":\"emotion\",\"text\":\":)\"},{\"tag\":\"unknown\"}]]}}",
   "content": "**Hello**\n\n`~~<u>***world***</u>~~`\n[click](https://x.com)[https://y.com](https://y.com)nolink\n@all@Zed@ou_nobody\n![image](img_1)<file key=\"file_9\"/>\n\n```ts\nlet x = 1\n```\n\n\n---\n\n:)",
   "resources": [
    {
     "type": "image",
     "fileKey": "img_1"
    },
    {
     "type": "file",
     "fileKey": "file_9"
    }
   ]
  },
  {
   "type": "post",
   "raw": "{\"en_us\":{\"content\":[[{\"tag\":\"text\",\"text\":\"english\"}]]},\"ja_jp\":{\"content\":[[{\"tag\":\"text\",\"text\":\"jp\"}]]}}",
   "content": "english",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"ko_kr\":{\"content\":[[{\"tag\":\"text\",\"text\":\"korean\"}]]},\"fr_fr\":{\"content\":[[{\"tag\":\"text\",\"text\":\"french\"}]]}}",
   "content": "korean",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"title\":\"\",\"content\":[[{\"tag\":\"text\",\"text\":\"flat\"}],\"notarray\"]}",
   "content": "flat",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"zh_cn\":{\"content\":[[null]]}}",
   "content": "[unsupported message]",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"zh_cn\":{\"content\":5}}",
   "content": "[unsupported message]",
   "resources": []
  },
  {
   "type": "post",
   "raw": "[{\"content\":[[{\"tag\":\"text\",\"text\":\"array body\"}]]}]",
   "content": "array body",
   "resources": []
  },
  {
   "type": "post",
   "raw": "{\"zh_cn\":{\"content\":[]}}",
   "content": "[rich text message]",
   "resources": []
  },
  {
   "type": "post",
   "raw": "not json",
   "content": "[rich text message]",
   "resources": []
  },
  {
   "type": "post",
   "raw": "\"s\"",
   "content": "[rich text message]",
   "resources": []
  },
  {
   "type": "merge_forward",
   "raw": "{}",
   "content": "<forwarded_messages/>",
   "resources": []
  },
  {
   "type": "unknown_type",
   "raw": "{\"text\":\"fallback body\"}",
   "content": "fallback body",
   "resources": []
  },
  {
   "type": "unknown_type",
   "raw": "{\"random\":\"data\"}",
   "content": "[unsupported message]",
   "resources": []
  },
  {
   "type": "unknown_type",
   "raw": "not-json",
   "content": "[unsupported message]",
   "resources": []
  }
 ],
 "normalize": [
  {
   "name": "basic",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "fallbackSender",
   "event": {
    "sender": {
     "sender_id": {
      "union_id": "on_x"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "on_x",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentions",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_user_1 please ask @_user_10 and @_bot\"}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_user_1",
       "id": {
        "open_id": "ou_bob"
       },
       "name": "Bob"
      },
      {
       "key": "@_user_10",
       "id": {
        "open_id": "ou_ten",
        "user_id": "u_ten"
       },
       "name": "Ten"
      },
      {
       "key": "@_bot",
       "id": {
        "open_id": "ou_bot"
       },
       "name": "TestBot"
      }
     ]
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@Bob please ask @Bob0 and",
    "rawContentType": "text",
    "resources": [],
    "mentions": [
     {
      "key": "@_user_1",
      "openId": "ou_bob",
      "name": "Bob",
      "isBot": false
     },
     {
      "key": "@_user_10",
      "openId": "ou_ten",
      "userId": "u_ten",
      "name": "Ten",
      "isBot": false
     },
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "TestBot",
      "isBot": true
     }
    ],
    "mentionAll": false,
    "mentionedBot": true,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentionsNoStrip",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_bot  help\\tme  now\"}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_bot",
       "id": {
        "open_id": "ou_bot"
       },
       "name": "TestBot"
      }
     ]
    }
   },
   "options": {
    "stripBotMentions": false
   },
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@TestBot help\tme now",
    "rawContentType": "text",
    "resources": [],
    "mentions": [
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "TestBot",
      "isBot": true
     }
    ],
    "mentionAll": false,
    "mentionedBot": true,
    "createTime": 1700000000000
   }
  },
  {
   "name": "botStripSpaces",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hey @_bot   there\"}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_bot",
       "id": {
        "open_id": "ou_bot"
       },
       "name": "TestBot"
      }
     ]
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "hey there",
    "rawContentType": "text",
    "resources": [],
    "mentions": [
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "TestBot",
      "isBot": true
     }
    ],
    "mentionAll": false,
    "mentionedBot": true,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentionAllArray",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_all listen\"}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_all",
       "id": {},
       "name": "所有人"
      }
     ]
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@所有人 listen",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": true,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentionAllContent",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_all  hi\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@_all  hi",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": true,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentionAllUnicode",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_all中文\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@_all中文",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": true,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "mentionAllied",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_allies\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@_allies",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "postMention",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "post",
     "content": "{\"zh_cn\":{\"title\":\"Greeting\",\"content\":[[{\"tag\":\"text\",\"text\":\"hi \"},{\"tag\":\"at\",\"user_id\":\"ou_bob\",\"user_name\":\"Bob\"}],[{\"tag\":\"img\",\"image_key\":\"img_1\"}]]}}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_user_1",
       "id": {
        "open_id": "ou_bob"
       },
       "name": "Bob"
      }
     ]
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "**Greeting**\n\nhi @Bob\n![image](img_1)",
    "rawContentType": "post",
    "resources": [
     {
      "type": "image",
      "fileKey": "img_1"
     }
    ],
    "mentions": [
     {
      "key": "@_user_1",
      "openId": "ou_bob",
      "name": "Bob",
      "isBot": false
     }
    ],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "noName",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"@_user_1 hi\"}",
     "create_time": "1700000000000",
     "mentions": [
      {
       "key": "@_user_1",
       "id": {
        "open_id": "ou_x"
       }
      }
     ]
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "@_user_1 hi",
    "rawContentType": "text",
    "resources": [],
    "mentions": [
     {
      "key": "@_user_1",
      "openId": "ou_x",
      "isBot": false
     }
    ],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "thread",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "p2p",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}",
     "create_time": "1700000000000",
     "root_id": "om_root",
     "parent_id": "om_parent",
     "thread_id": "omt_1"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "p2p",
    "senderId": "ou_alice",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "rootId": "om_root",
    "threadId": "omt_1",
    "replyToMessageId": "om_parent",
    "createTime": 1700000000000
   }
  },
  {
   "name": "badCreate",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}",
     "create_time": "abc"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 0
   }
  },
  {
   "name": "noCreate",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}"
    }
   },
   "options": {},
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 0
   }
  },
  {
   "name": "mergeForward",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_fw",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "merge_forward",
     "content": "{}",
     "create_time": "1700000000000"
    }
   },
   "options": {
    "forward": true
   },
   "result": {
    "messageId": "om_fw",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "content": "<forwarded_messages>\n[2026-04-21T14:39:09+08:00] Alice:\n    first\n    line2\n[2026-04-21T14:41:09+08:00] ou_bob:\n    second\n[2026-04-21T14:41:40+08:00] ou_carol:\n    <forwarded_messages>\n    [unknown] ou_dan:\n        ![image](img_n)\n    </forwarded_messages>\n[2026-04-21T14:43:20+08:00] unknown:\n    p\n</forwarded_messages>",
    "rawContentType": "merge_forward",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  },
  {
   "name": "senderName",
   "event": {
    "sender": {
     "sender_id": {
      "open_id": "ou_alice",
      "user_id": "u_alice"
     }
    },
    "message": {
     "message_id": "om_x",
     "chat_id": "oc_test",
     "chat_type": "group",
     "message_type": "text",
     "content": "{\"text\":\"hello\"}",
     "create_time": "1700000000000"
    }
   },
   "options": {
    "senderName": true
   },
   "result": {
    "messageId": "om_x",
    "chatId": "oc_test",
    "chatType": "group",
    "senderId": "ou_alice",
    "senderName": "Alice",
    "content": "hello",
    "rawContentType": "text",
    "resources": [],
    "mentions": [],
    "mentionAll": false,
    "mentionedBot": false,
    "createTime": 1700000000000
   }
  }
 ],
 "forwardItems": [
  {
   "message_id": "om_fw",
   "msg_type": "merge_forward",
   "body": {
    "content": "Merged and Forwarded Message"
   },
   "sender": {
    "id": "ou_fwd"
   },
   "create_time": "1776849870916"
  },
  {
   "message_id": "om_c2",
   "upper_message_id": "om_fw",
   "msg_type": "text",
   "body": {
    "content": "{\"text\":\"second\"}"
   },
   "sender": {
    "id": "ou_bob"
   },
   "create_time": "1776753669281"
  },
  {
   "message_id": "om_c1",
   "upper_message_id": "om_fw",
   "msg_type": "text",
   "body": {
    "content": "{\"text\":\"first\\nline2\"}"
   },
   "sender": {
    "id": "ou_alice"
   },
   "create_time": "1776753549563"
  },
  {
   "message_id": "om_nested",
   "upper_message_id": "om_fw",
   "msg_type": "merge_forward",
   "body": {
    "content": ""
   },
   "sender": {
    "id": "ou_carol"
   },
   "create_time": "1776753700000"
  },
  {
   "message_id": "om_n1",
   "upper_message_id": "om_nested",
   "msg_type": "image",
   "body": {
    "content": "{\"image_key\":\"img_n\"}"
   },
   "sender": {
    "id": "ou_dan"
   }
  },
  {
   "message_id": "om_c3",
   "upper_message_id": "om_fw",
   "msg_type": "post",
   "body": {
    "content": "{\"zh_cn\":{\"content\":[[{\"tag\":\"text\",\"text\":\"p\"}]]}}"
   },
   "create_time": 1776753800000
  }
 ],
 "eventNormalizers": {
  "cardAction": [
   [
    {
     "context": {
      "open_message_id": "om_1",
      "open_chat_id": "oc_1"
     },
     "operator": {
      "open_id": "ou_a",
      "user_id": "u_a",
      "name": "A"
     },
     "action": {
      "value": {
       "k": "v"
      },
      "tag": "button",
      "name": "n",
      "option": "o"
     }
    },
    {
     "messageId": "om_1",
     "chatId": "oc_1",
     "operator": {
      "openId": "ou_a",
      "userId": "u_a",
      "name": "A"
     },
     "action": {
      "value": {
       "k": "v"
      },
      "tag": "button",
      "name": "n",
      "option": "o"
     }
    }
   ],
   [
    {
     "open_message_id": "om_t",
     "open_chat_id": "oc_t",
     "operator": {
      "open_id": "ou_a"
     },
     "action": {}
    },
    {
     "messageId": "om_t",
     "chatId": "oc_t",
     "operator": {
      "openId": "ou_a"
     },
     "action": {
      "tag": "unknown"
     }
    }
   ],
   [
    {
     "context": {
      "open_message_id": "",
      "open_chat_id": "oc_1"
     },
     "open_message_id": "om_top",
     "operator": {
      "open_id": "ou_a"
     }
    },
    null
   ],
   [
    {
     "context": {
      "open_chat_id": "oc_1"
     },
     "open_message_id": "om_top",
     "operator": {
      "open_id": "ou_a"
     },
     "action": {
      "value": null,
      "tag": "select"
     }
    },
    {
     "messageId": "om_top",
     "chatId": "oc_1",
     "operator": {
      "openId": "ou_a"
     },
     "action": {
      "value": null,
      "tag": "select"
     }
    }
   ]
  ],
  "reaction": [
   [
    {
     "message_id": "om_1",
     "reaction_type": {
      "emoji_type": "OK"
     },
     "user_id": {
      "open_id": "ou_a",
      "user_id": null
     },
     "action_time": "1000000000000"
    },
    {
     "messageId": "om_1",
     "operator": {
      "openId": "ou_a"
     },
     "emojiType": "OK",
     "action": "added",
     "actionTime": 1000000000000
    }
   ],
   [
    {
     "message_id": "om_1",
     "reaction_type": {
      "emoji_type": "OK"
     },
     "user_id": {
      "open_id": "ou_a",
      "user_id": "u_a"
     },
     "action_time": "x"
    },
    {
     "messageId": "om_1",
     "operator": {
      "openId": "ou_a",
      "userId": "u_a"
     },
     "emojiType": "OK",
     "action": "added"
    }
   ],
   [
    {
     "message_id": "om_1",
     "reaction_type": {
      "emoji_type": ""
     },
     "user_id": {
      "open_id": "ou_a"
     }
    },
    null
   ]
  ],
  "botAdded": [
   [
    {
     "chat_id": "oc_1",
     "operator_id": {
      "open_id": "ou_a",
      "user_id": null
     },
     "i18n_names": {
      "ja_jp": "JP"
     },
     "external": false
    },
    {
     "chatId": "oc_1",
     "operator": {
      "openId": "ou_a"
     },
     "botName": "JP",
     "external": false
    }
   ],
   [
    {
     "chat_id": "oc_1",
     "operator_id": {
      "open_id": "ou_a"
     },
     "name": "",
     "i18n_names": {
      "zh_cn": "ZH"
     }
    },
    {
     "chatId": "oc_1",
     "operator": {
      "openId": "ou_a"
     },
     "botName": ""
    }
   ],
   [
    {
     "chat_id": "oc_1",
     "operator_id": {}
    },
    null
   ]
  ],
  "comment": [
   [
    {
     "comment_id": "c1",
     "is_mentioned": false,
     "create_time": "1776838695000",
     "notice_meta": {
      "file_token": "ft",
      "file_type": "docx",
      "from_user_id": {
       "open_id": "ou_a",
       "union_id": "on_a",
       "user_id": null
      },
      "is_mentioned": true
     }
    },
    {
     "fileToken": "ft",
     "fileType": "docx",
     "commentId": "c1",
     "operator": {
      "openId": "ou_a",
      "unionId": "on_a"
     },
     "mentionedBot": false,
     "timestamp": 1776838695000
    }
   ],
   [
    {
     "file_token": "ft",
     "file_type": "sheet",
     "comment_id": "c2",
     "notice_meta": {
      "timestamp": "1700000000000",
      "from_user_id": {
       "open_id": "ou_b"
      }
     },
     "is_mention": true
    },
    {
     "fileToken": "ft",
     "fileType": "sheet",
     "commentId": "c2",
     "operator": {
      "openId": "ou_b"
     },
     "mentionedBot": true,
     "timestamp": 1700000000000
    }
   ],
   [
    {
     "file_token": "ft",
     "file_type": "doc",
     "comment_id": "c3",
     "user_id": {
      "open_id": "ou_c",
      "user_id": "u_c"
     },
     "action_time": "1700000000001"
    },
    {
     "fileToken": "ft",
     "fileType": "doc",
     "commentId": "c3",
     "operator": {
      "openId": "ou_c",
      "userId": "u_c"
     },
     "mentionedBot": false,
     "timestamp": 1700000000001
    }
   ]
  ]
 },
 "resolveMentions": [
  [
   "hello @_user_1",
   [
    [
     "@_user_1",
     {
      "key": "@_user_1",
      "openId": "ou_a",
      "name": "Alice",
      "isBot": false
     }
    ]
   ],
   true,
   "hello @Alice"
  ],
  [
   "@_bot help me",
   [
    [
     "@_bot",
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "Bot",
      "isBot": true
     }
    ]
   ],
   true,
   "help me"
  ],
  [
   "@_bot help me",
   [
    [
     "@_bot",
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "Bot",
      "isBot": true
     }
    ]
   ],
   false,
   "@Bot help me"
  ],
  [
   "a @_bot\n@_bot b",
   [
    [
     "@_bot",
     {
      "key": "@_bot",
      "openId": "ou_bot",
      "name": "Bot",
      "isBot": true
     }
    ]
   ],
   true,
   "a b"
  ],
  [
   "x  y\t\tz",
   [
    [
     "@_u",
     {
      "key": "@_u",
      "name": "U",
      "isBot": false
     }
    ]
   ],
   true,
   "x y z"
  ],
  [
   "@_user_1 $& @_user_2",
   [
    [
     "@_user_1",
     {
      "key": "@_user_1",
      "name": "$1",
      "isBot": false
     }
    ],
    [
     "@_user_2",
     {
      "key": "@_user_2",
      "name": "",
      "isBot": false
     }
    ]
   ],
   true,
   "@$1 $& @_user_2"
  ],
  [
   "  keep  ",
   [],
   true,
   "  keep  "
  ]
 ],
 "markdownToPost": [
  [
   "hello world",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"hello world\"}]]}}"
  ],
  [
   "# Title\n\nbody",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#### Title\\n\\nbody\"}]]}}"
  ],
  [
   "# A\n\n## B\n\n### C\n\n#### D\n\n###### F",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#### A\\n\\n##### B\\n\\n##### C\\n\\n##### D\\n\\n##### F\"}]]}}"
  ],
  [
   "#### existing H4",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#### existing H4\"}]]}}"
  ],
  [
   "a\n\n\n\nb",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"a\\n\\nb\"}]]}}"
  ],
  [
   "# heading\n\n```ts\n# not a heading inside code\n```",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#### heading\\n\\n```ts\\n# not a heading inside code\\n```\"}]]}}"
  ],
  [
   "```bash\necho $'x' $& $` done\n```\ntext",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"```bash\\necho \\ntextx' ___CB_0___  done\\n```\\ntext\"}]]}}"
  ],
  [
   "## Sub\ntext\n### Third",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"##### Sub\\ntext\\n##### Third\"}]]}}"
  ],
  [
   "text\n| a | b |\n|---|---|\n| 1 | 2 |\nafter",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"text\\n| a | b |\\n|---|---|\\n| 1 | 2 |\\nafter\"}]]}}"
  ],
  [
   "#### H4\n#### H4b\n\n##### H5",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#### H4\\n#### H4b\\n\\n##### H5\"}]]}}"
  ],
  [
   "**bold**\n\n| t |\n| - |\ntrail",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"**bold**\\n\\n| t |\\n| - |\\ntrail\"}]]}}"
  ],
  [
   "line\n```\ncode\n```\n```\nmore\n```",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"line\\n```\\ncode\\n```\\n```\\nmore\\n```\"}]]}}"
  ],
  [
   "````md\n```inner```\n````",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"````md\\n```inner```\\n````\"}]]}}"
  ],
  [
   "x\r\n# y",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"x\\r\\n#### y\"}]]}}"
  ],
  [
   "para\n\n| a |\n|---|\n\n---\nend",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"para\\n\\n| a |\\n|---|\\n\\n---\\nend\"}]]}}"
  ],
  [
   "| only | table |\n|---|---|",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"| only | table |\\n|---|---|\"}]]}}"
  ],
  [
   "#Not heading\n# Real",
   "{\"zh_cn\":{\"title\":\"\",\"content\":[[{\"tag\":\"md\",\"text\":\"#Not heading\\n#### Real\"}]]}}"
  ]
 ],
 "markdownToPostMentions": "{\"zh_cn\":{\"title\":\"T\",\"content\":[[{\"tag\":\"md\",\"text\":\"<at user_id=\\\"ou_a\\\">Alice</at> <at user_id=\\\"ou_b\\\"></at> hi\"}]]}}",
 "optimizeV2": [
  [
   "hello world",
   "hello world"
  ],
  [
   "# Title\n\nbody",
   "#### Title\n\nbody"
  ],
  [
   "# A\n\n## B\n\n### C\n\n#### D\n\n###### F",
   "#### A\n<br>\n##### B\n\n##### C\n<br>\n##### D\n\n##### F"
  ],
  [
   "#### existing H4",
   "#### existing H4"
  ],
  [
   "a\n\n\n\nb",
   "a\n\nb"
  ],
  [
   "# heading\n\n```ts\n# not a heading inside code\n```",
   "#### heading\n\n<br>\n```ts\n# not a heading inside code\n```\n<br>\n"
  ],
  [
   "```bash\necho $'x' $& $` done\n```\ntext",
   "\n<br>\n```bash\necho \ntextx' ___CB_0___  done\n```\n<br>\n\ntext"
  ],
  [
   "## Sub\ntext\n### Third",
   "##### Sub\ntext\n##### Third"
  ],
  [
   "text\n| a | b |\n|---|---|\n| 1 | 2 |\nafter",
   "text\n<br>\n| a | b |\n|---|---|\n| 1 | 2 |\n<br>\nafter"
  ],
  [
   "#### H4\n#### H4b\n\n##### H5",
   "#### H4\n<br>\n#### H4b\n\n##### H5"
  ],
  [
   "**bold**\n\n| t |\n| - |\ntrail",
   "**bold**\n<br>\n\n| t |\n| - |\n<br>\ntrail"
  ],
  [
   "line\n```\ncode\n```\n```\nmore\n```",
   "line\n\n<br>\n```\ncode\n```\n<br>\n\n<br>\n```\nmore\n```\n<br>\n"
  ],
  [
   "````md\n```inner```\n````",
   "\n<br>\n````md\n```inner```\n````\n<br>\n"
  ],
  [
   "x\r\n# y",
   "x\r\n#### y"
  ],
  [
   "para\n\n| a |\n|---|\n\n---\nend",
   "para\n<br>\n| a |\n|---|\n\n---\nend"
  ],
  [
   "| only | table |\n|---|---|",
   "| only | table |\n|---|---|"
  ],
  [
   "#Not heading\n# Real",
   "#Not heading\n#### Real"
  ]
 ],
 "split": [
  [
   "hello",
   100,
   [
    "hello"
   ]
  ],
  [
   "",
   100,
   [
    ""
   ]
  ],
  [
   "aaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa\naaaaaaaa",
   30,
   [
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa\naaaaaaaa",
    "aaaaaaaa\naaaaaaaa"
   ]
  ],
  [
   "```ts\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n```",
   40,
   [
    "```ts\n```",
    "```ts\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n```",
    "```ts\nyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n```",
    "```ts\n```"
   ]
  ],
  [
   "```python\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n```",
   40,
   [
    "```python\n```",
    "```python\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n```",
    "```python\n```"
   ]
  ],
  [
   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n## Heading\nafter",
   40,
   [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "## Heading\nafter"
   ]
  ],
  [
   "one\ntwo\n```\ncode1\ncode2\ncode3\n```\nthree\n# H\nfour",
   15,
   [
    "one\ntwo\n```\n```",
    "```\ncode1\ncode2\n```",
    "```\ncode3\n```",
    "three\n# H\nfour"
   ]
  ],
  [
   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
   10,
   [
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ]
  ],
  [
   "中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文\n😀😀😀😀😀😀😀😀😀😀",
   30,
   [
    "中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文",
    "😀😀😀😀😀😀😀😀😀😀"
   ]
  ]
 ],
 "merge": [
  [
   "",
   "hello",
   "hello"
  ],
  [
   "hello",
   "",
   "hello"
  ],
  [
   "hello",
   "hello world",
   "hello world"
  ],
  [
   "hello world",
   "hello",
   "hello world"
  ],
  [
   "hello wor",
   "world foo",
   "hello world foo"
  ],
  [
   "abc",
   "xyz",
   "abcxyz"
  ],
  [
   "foo",
   "oo bar",
   "foo bar"
  ],
  [
   "aaa",
   "aab",
   "aaab"
  ],
  [
   "ab",
   "ba",
   "aba"
  ]
 ],
 "postToPlainText": [
  [
   {
    "zh_cn": {
     "title": "",
     "content": [
      [
       {
        "tag": "md",
        "text": "hello **world** [link](https://x)"
       }
      ]
     ]
    }
   },
   "hello **world** [link](https://x)"
  ],
  [
   {
    "zh_cn": {
     "content": [
      [
       {
        "tag": "text",
        "text": "hello "
       },
       {
        "tag": "at",
        "user_name": "Alice"
       },
       {
        "tag": "text",
        "text": " see "
       },
       {
        "tag": "a",
        "text": "docs",
        "href": "https://x"
       },
       {
        "tag": "img",
        "image_key": "img_1"
       }
      ],
      [
       {
        "tag": "at"
       },
       {
        "tag": "img"
       },
       {
        "tag": "hr"
       }
      ],
      "skip",
      [
       {
        "tag": "md",
        "text": "  tail  "
       }
      ]
     ]
    }
   },
   "hello @Alice see docs[image]\n\n  tail"
  ],
  [
   {
    "en_us": {
     "content": [
      [
       {
        "tag": "text",
        "text": "x"
       }
      ]
     ]
    }
   },
   ""
  ],
  [
   null,
   ""
  ],
  [
   {},
   ""
  ]
 ],
 "composeText": "<at user_id=\"ou_a\">A</at> <at user_id=\"ou_b\"></at> ",
 "ogg": [
  [
   "6a756e6b4f6767530000c05d000000000000010000000000000000000000000102034f67675300000077010000000000010000000000000000000000000000000000",
   2000
  ],
  [
   "4f676753000080bb00000000000001000000000000000000000000",
   1000
  ],
  [
   "4f6767530000581901000000000001000000000000000000000000",
   1501
  ],
  [
   "4f6767530000ffffffffffffffff01000000000000000000000000",
   null
  ],
  [
   "00000000000000000000",
   null
  ],
  [
   "6e6f7420616e206f67672066696c65206865726520617420616c6c20617420616c6c",
   null
  ],
  [
   "4f67675300002f0000000000000001000000000000000000000000",
   1
  ]
 ],
 "mp4": [
  [
   "000000746d6f6f760000006c6d766864000000000000000000000000000003e8000075300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   30000
  ],
  [
   "000000186674797069736f6d0000000069736f6d61766331000000806d6f6f760000000c7472616b000000000000006c6d7668640000000000000000000000000000025800000e110000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   6002
  ],
  [
   "000000806d6f6f76000000786d76686401000000000000000000000000000000000000000000bb80000000001c9c38000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   10000000
  ],
  [
   "000000016d6f6f76000000000000007c0000006c6d766864000000000000000000000000000003e8000010e10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   4321
  ],
  [
   "000000186674797069736f6d0000000069736f6d61766331000000006d6f6f760000006c6d76686400000000000000000000000000015f90000dbba00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   10000
  ],
  [
   "000000746d6f6f760000006c6d766864000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   null
  ],
  [
   "0000001c6d6461740000000000000000000000000000000000000000000000746d6f6f760000006c6d766864000000000000000000000000000003e8000003e70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   999
  ],
  [
   "000000006d6461740000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   null
  ],
  [
   "74686973206973206e6f7420616e206d70342066696c6520617420616c6c207265616c6c79206e6f7468696e6720746f207365652068657265",
   null
  ],
  [
   "0000270f6d6f6f760000006c6d766864000000000000000000000000000003e8000000050000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
   null
  ]
 ],
 "ssrf": [
  {
   "url": "https://example.com/x",
   "records": [
    {
     "address": "8.8.8.8",
     "family": 4
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "8.8.8.8",
     "originalHost": "example.com"
    }
   }
  },
  {
   "url": "http://evil.com/",
   "records": [
    {
     "address": "169.254.169.254",
     "family": 4
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 169.254.169.254"
   }
  },
  {
   "url": "http://evil.com/",
   "records": [
    {
     "address": "8.8.8.8",
     "family": 4
    },
    {
     "address": "169.254.169.254",
     "family": 4
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 169.254.169.254"
   }
  },
  {
   "url": "http://1.2.3.4/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "1.2.3.4",
     "originalHost": "1.2.3.4"
    }
   }
  },
  {
   "url": "http://169.254.169.254/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 169.254.169.254"
   }
  },
  {
   "url": "http://[::1]/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: ::1"
   }
  },
  {
   "url": "http://[::ffff:127.0.0.1]/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: ::ffff:7f00:1"
   }
  },
  {
   "url": "http://[::ffff:8.8.8.8]:8080/p",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "::ffff:808:808",
     "originalHost": "::ffff:808:808"
    }
   }
  },
  {
   "url": "http://[2001:4860:4860:0:0:0:0:8888]/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "2001:4860:4860::8888",
     "originalHost": "2001:4860:4860::8888"
    }
   }
  },
  {
   "url": "HTTP://Example.COM/",
   "records": [
    {
     "address": "93.184.216.34",
     "family": 4
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "93.184.216.34",
     "originalHost": "example.com"
    }
   }
  },
  {
   "url": "http://2130706433/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 127.0.0.1"
   }
  },
  {
   "url": "http://0x7f.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 127.0.0.1"
   }
  },
  {
   "url": "http://010.0.0.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "8.0.0.1",
     "originalHost": "8.0.0.1"
    }
   }
  },
  {
   "url": "http://8.8.8.8./",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "8.8.8.8",
     "originalHost": "8.8.8.8"
    }
   }
  },
  {
   "url": "http://exp.test/",
   "records": [
    {
     "address": "0:0:0:0:0:ffff:7f00:1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 0:0:0:0:0:ffff:7f00:1"
   }
  },
  {
   "url": "http://c.test/",
   "records": [
    {
     "address": "::7f00:1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: ::7f00:1"
   }
  },
  {
   "url": "http://n.test/",
   "records": [
    {
     "address": "64:ff9b::a00:1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 64:ff9b::a00:1"
   }
  },
  {
   "url": "http://n.test/",
   "records": [
    {
     "address": "64:ff9b::808:808",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "64:ff9b::808:808",
     "originalHost": "n.test"
    }
   }
  },
  {
   "url": "http://d.test/",
   "records": [
    {
     "address": "2001:db8::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 2001:db8::1"
   }
  },
  {
   "url": "http://t.test/",
   "records": [
    {
     "address": "2001:0:1234::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 2001:0:1234::1"
   }
  },
  {
   "url": "http://g.test/",
   "records": [
    {
     "address": "2001:4860:4860::8888",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "2001:4860:4860::8888",
     "originalHost": "g.test"
    }
   }
  },
  {
   "url": "http://l.test/",
   "records": [
    {
     "address": "fe80::1%eth0",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: fe80::1%eth0"
   }
  },
  {
   "url": "http://u.test/",
   "records": [
    {
     "address": "fc12:3456::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: fc12:3456::1"
   }
  },
  {
   "url": "http://u.test/",
   "records": [
    {
     "address": "fd00:abcd::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: fd00:abcd::1"
   }
  },
  {
   "url": "http://lo.test/",
   "records": [
    {
     "address": "0:0:0:0:0:0:0:1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 0:0:0:0:0:0:0:1"
   }
  },
  {
   "url": "http://bad.test/",
   "records": [
    {
     "address": "not::an::ipv6",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: not a valid IP: not::an::ipv6"
   }
  },
  {
   "url": "http://m.test/",
   "records": [
    {
     "address": "ff02::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: ff02::1"
   }
  },
  {
   "url": "http://dz.test/",
   "records": [
    {
     "address": "100::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 100::1"
   }
  },
  {
   "url": "http://dz.test/",
   "records": [
    {
     "address": "100:0:0:1::1",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "100:0:0:1::1",
     "originalHost": "dz.test"
    }
   }
  },
  {
   "url": "http://m4.test/",
   "records": [
    {
     "address": "::ffff:10.1.2.3",
     "family": 6
    }
   ],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: ::ffff:10.1.2.3"
   }
  },
  {
   "url": "file:///etc/passwd",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: protocol file:"
   }
  },
  {
   "url": "gopher://evil.com/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: protocol gopher:"
   }
  },
  {
   "url": "http://nx.invalid/",
   "records": [],
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: no DNS records for nx.invalid"
   }
  },
  {
   "url": "http://internal.corp/",
   "records": [
    {
     "address": "10.0.0.1",
     "family": 4
    }
   ],
   "allowlist": [
    "internal.corp"
   ],
   "result": {
    "ok": {
     "resolvedIp": "10.0.0.1",
     "originalHost": "internal.corp"
    }
   }
  },
  {
   "url": "http://100.64.0.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 100.64.0.1"
   }
  },
  {
   "url": "http://100.128.0.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "100.128.0.1",
     "originalHost": "100.128.0.1"
    }
   }
  },
  {
   "url": "http://p.test/",
   "records": [
    {
     "address": "8.8.8.8",
     "family": 4
    },
    {
     "address": "1.1.1.1",
     "family": 4
    }
   ],
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "8.8.8.8",
     "originalHost": "p.test"
    }
   }
  },
  {
   "url": "http://172.15.255.255/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "172.15.255.255",
     "originalHost": "172.15.255.255"
    }
   }
  },
  {
   "url": "http://172.16.0.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 172.16.0.1"
   }
  },
  {
   "url": "http://192.0.2.5/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 192.0.2.5"
   }
  },
  {
   "url": "http://198.19.1.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 198.19.1.1"
   }
  },
  {
   "url": "http://198.20.1.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "198.20.1.1",
     "originalHost": "198.20.1.1"
    }
   }
  },
  {
   "url": "http://224.0.0.1/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 224.0.0.1"
   }
  },
  {
   "url": "http://255.255.255.255/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: 255.255.255.255"
   }
  },
  {
   "url": "http://user:pw@8.8.4.4:99/x?y#z",
   "records": null,
   "allowlist": null,
   "result": {
    "ok": {
     "resolvedIp": "8.8.4.4",
     "originalHost": "8.8.4.4"
    }
   }
  },
  {
   "url": "https://[fe80::1]/",
   "records": null,
   "allowlist": null,
   "result": {
    "error": "ssrf_blocked: fe80::1"
   }
  }
 ],
 "hostnames": [
  [
   "http://[0:0:0:0:0:0:0:1]/",
   "[::1]"
  ],
  [
   "http://[::FFFF:127.0.0.1]/",
   "[::ffff:7f00:1]"
  ],
  [
   "http://[1:0:0:2:0:0:0:3]/",
   "[1:0:0:2::3]"
  ],
  [
   "http://[1:0:0:0:2:0:0:3]/",
   "[1::2:0:0:3]"
  ],
  [
   "http://[0:1:0:1:0:1:0:1]/",
   "[0:1:0:1:0:1:0:1]"
  ],
  [
   "http://0x7f000001/",
   "127.0.0.1"
  ],
  [
   "http://0177.0.0.1/",
   "127.0.0.1"
  ],
  [
   "http://1.2.3/",
   "1.2.0.3"
  ],
  [
   "http://Foo.Example.com:80/",
   "foo.example.com"
  ]
 ],
 "wire": {
  "text": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"hello \\\\\\\"world\\\\\\\"\\\\n/slash 中文 😀\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "textMentionsReply": {
   "calls": [
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_parent/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"text\\\":\\\"<at user_id=\\\\\\\"ou_a\\\\\\\">A</at> hi\\\"}\",\"msg_type\":\"text\",\"reply_in_thread\":true}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "textChunks": {
   "calls": [
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_r/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"text\\\":\\\"abcdefghij\\\"}\",\"msg_type\":\"text\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "union_id"
     },
     "body": "{\"receive_id\":\"on_union\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"klmnopqrst\\\"}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "union_id"
     },
     "body": "{\"receive_id\":\"on_union\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"uvwxy\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1",
    "chunkIds": [
     "om_1",
     "om_2",
     "om_3"
    ]
   },
   "error": null,
   "config": {}
  },
  "markdown": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"title\\\":\\\"\\\",\\\"content\\\":[[{\\\"tag\\\":\\\"md\\\",\\\"text\\\":\\\"<at user_id=\\\\\\\"ou_a\\\\\\\">Alice</at> # Title\\\\n\\\\nbody **bold** `code`\\\\n\\\\nend\\\"}]]}}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "markdownChunks": {
   "calls": [
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_r/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"zh_cn\\\":{\\\"title\\\":\\\"\\\",\\\"content\\\":[[{\\\"tag\\\":\\\"md\\\",\\\"text\\\":\\\"<at user_id=\\\\\\\"ou_a\\\\\\\">Alice</at> para one line\\\\npara two line\\\\n```js\\\\n```\\\"}]]}}\",\"msg_type\":\"post\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "email"
     },
     "body": "{\"receive_id\":\"alice@example.com\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"title\\\":\\\"\\\",\\\"content\\\":[[{\\\"tag\\\":\\\"md\\\",\\\"text\\\":\\\"```js\\\\nconst a = 1;\\\\nconst b = 2;\\\\n```\\\"}]]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "email"
     },
     "body": "{\"receive_id\":\"alice@example.com\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"title\\\":\\\"\\\",\\\"content\\\":[[{\\\"tag\\\":\\\"md\\\",\\\"text\\\":\\\"##### Next\\\\nmore text here\\\"}]]}}\"}"
    }
   ],
   "result": {
    "messageId": "om_1",
    "chunkIds": [
     "om_1",
     "om_2",
     "om_3"
    ]
   },
   "error": null,
   "config": {}
  },
  "post": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"content\\\":[[{\\\"tag\\\":\\\"text\\\",\\\"text\\\":\\\"x\\\"}]],\\\"title\\\":\\\"t\\\"}}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "card": {
   "calls": [
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_r/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"body\\\":{\\\"elements\\\":[{\\\"content\\\":\\\"hi\\\",\\\"tag\\\":\\\"markdown\\\"}]},\\\"schema\\\":\\\"2.0\\\"}\",\"msg_type\":\"interactive\",\"reply_in_thread\":false}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "shareChat": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"share_chat\",\"content\":\"{\\\"chat_id\\\":\\\"oc_target\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "shareUser": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"share_user\",\"content\":\"{\\\"user_id\\\":\\\"ou_alice\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "sticker": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "user_id"
     },
     "body": "{\"receive_id\":\"u_plain\",\"msg_type\":\"sticker\",\"content\":\"{\\\"file_key\\\":\\\"sticker_abc\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "image": {
   "calls": [
    {
     "api": "image.create",
     "method": "POST",
     "path": "/open-apis/im/v1/images",
     "query": null,
     "form": {
      "image_type": "message",
      "image": {
       "hex": "010203"
      }
     }
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"image\",\"content\":\"{\\\"image_key\\\":\\\"img_up\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "file": {
   "calls": [
    {
     "api": "file.create",
     "method": "POST",
     "path": "/open-apis/im/v1/files",
     "query": null,
     "form": {
      "file_type": "stream",
      "file_name": "a.txt",
      "file": {
       "hex": "646f63"
      }
     }
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"file\",\"content\":\"{\\\"file_key\\\":\\\"file_up\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "audio": {
   "calls": [
    {
     "api": "file.create",
     "method": "POST",
     "path": "/open-apis/im/v1/files",
     "query": null,
     "form": {
      "file_type": "opus",
      "file_name": "voice.opus",
      "file": {
       "hex": "6f707573"
      },
      "duration": 3000
     }
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"audio\",\"content\":\"{\\\"file_key\\\":\\\"file_up\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "video": {
   "calls": [
    {
     "api": "file.create",
     "method": "POST",
     "path": "/open-apis/im/v1/files",
     "query": null,
     "form": {
      "file_type": "mp4",
      "file_name": "video.mp4",
      "file": {
       "hex": "6d7034"
      },
      "duration": 5000
     }
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"media\",\"content\":\"{\\\"file_key\\\":\\\"file_up\\\",\\\"image_key\\\":\\\"img_cover\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "postFallback": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"content\\\":[[{\\\"tag\\\":\\\"text\\\",\\\"text\\\":\\\"hello\\\"},{\\\"tag\\\":\\\"at\\\",\\\"user_name\\\":\\\"Al\\\"}]],\\\"title\\\":\\\"bad\\\"}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"hello@Al\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "markdownFallbackEmpty": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"post\",\"content\":\"{\\\"zh_cn\\\":{\\\"title\\\":\\\"\\\",\\\"content\\\":[[{\\\"tag\\\":\\\"md\\\",\\\"text\\\":\\\"\\\"}]]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"[message]\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "replyRevoked": {
   "calls": [
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_gone/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"text\\\":\\\"hi\\\"}\",\"msg_type\":\"text\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"hi\\\"}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {}
  },
  "streamMarkdown": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"Thinking...\\\"}]}}\"}"
    },
    {
     "api": "message.reply",
     "method": "POST",
     "path": "/open-apis/im/v1/messages/om_r/reply",
     "query": null,
     "body": "{\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\",\"msg_type\":\"interactive\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"Hello world and more   text\\nnew line\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"Hello world and more text new line\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_1_2\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000
   }
  },
  "streamMarkdownEmpty": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"...\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"...\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"(no content)\",\"sequence\":2,\"uuid\":\"c_card_1_2\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"(no content)\\\"}}}\",\"sequence\":3,\"uuid\":\"s_card_1_3\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000,
    "streamInitialText": ""
   }
  },
  "streamMarkdownSetContent": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"Wait\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"replaced\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"replaced\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_1_2\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000,
    "streamInitialText": "Wait"
   }
  },
  "streamMarkdownRollover": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"Thinking...\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"line one is here\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"line one is here\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_1_2\"}"
    },
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"line two is here\\\\nline three here\\\\nfour\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_2\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_2/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"line two is here\",\"sequence\":1,\"uuid\":\"c_card_2_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_2/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"line two is here\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_2_2\"}"
    },
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"line three here\\\\nfour\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_3\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_3/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"line three here\\nfour\",\"sequence\":1,\"uuid\":\"c_card_3_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_3/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"line three here four\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_3_2\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000,
    "streamMaxElementChars": 20
   }
  },
  "streamMarkdownLongSummary": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"Thinking...\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_1_2\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000
   }
  },
  "streamCard": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"elements\\\":[{\\\"content\\\":\\\"v0\\\",\\\"tag\\\":\\\"markdown\\\"}],\\\"schema\\\":\\\"2.0\\\"}\"}"
    },
    {
     "api": "message.patch",
     "method": "PATCH",
     "path": "/open-apis/im/v1/messages/om_1",
     "query": null,
     "body": "{\"content\":\"{\\\"elements\\\":[{\\\"content\\\":\\\"v1\\\",\\\"tag\\\":\\\"markdown\\\"}],\\\"schema\\\":\\\"2.0\\\",\\\"header\\\":{\\\"title\\\":\\\"T\\\"}}\"}"
    }
   ],
   "result": {
    "messageId": "om_1"
   },
   "error": null,
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000
   }
  },
  "streamMarkdownFail": {
   "calls": [
    {
     "api": "card.create",
     "method": "POST",
     "path": "/open-apis/cardkit/v1/cards",
     "query": null,
     "body": "{\"type\":\"card_json\",\"data\":\"{\\\"schema\\\":\\\"2.0\\\",\\\"config\\\":{\\\"streaming_mode\\\":true,\\\"summary\\\":{\\\"content\\\":\\\"[Generating...]\\\"},\\\"streaming_config\\\":{\\\"print_frequency_ms\\\":{\\\"default\\\":70},\\\"print_step\\\":{\\\"default\\\":1},\\\"print_strategy\\\":\\\"fast\\\"}},\\\"body\\\":{\\\"elements\\\":[{\\\"tag\\\":\\\"markdown\\\",\\\"element_id\\\":\\\"stream_md\\\",\\\"content\\\":\\\"Thinking...\\\"}]}}\"}"
    },
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"type\\\":\\\"card\\\",\\\"data\\\":{\\\"card_id\\\":\\\"card_1\\\"}}\"}"
    },
    {
     "api": "cardElement.content",
     "method": "PUT",
     "path": "/open-apis/cardkit/v1/cards/card_1/elements/stream_md/content",
     "query": null,
     "body": "{\"content\":\"partial\\n\\n— _(Generation interrupted)_\",\"sequence\":1,\"uuid\":\"c_card_1_1\"}"
    },
    {
     "api": "card.settings",
     "method": "PATCH",
     "path": "/open-apis/cardkit/v1/cards/card_1/settings",
     "query": null,
     "body": "{\"settings\":\"{\\\"config\\\":{\\\"streaming_mode\\\":false,\\\"summary\\\":{\\\"content\\\":\\\"partial — _(Generation interrupted)_\\\"}}}\",\"sequence\":2,\"uuid\":\"s_card_1_2\"}"
    }
   ],
   "result": null,
   "error": "producer failure",
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000
   }
  },
  "streamCardFail": {
   "calls": [
    {
     "api": "message.create",
     "method": "POST",
     "path": "/open-apis/im/v1/messages",
     "query": {
      "receive_id_type": "chat_id"
     },
     "body": "{\"receive_id\":\"oc_chat\",\"msg_type\":\"interactive\",\"content\":\"{\\\"elements\\\":[{\\\"tag\\\":\\\"div\\\"}]}\"}"
    },
    {
     "api": "message.patch",
     "method": "PATCH",
     "path": "/open-apis/im/v1/messages/om_1",
     "query": null,
     "body": "{\"content\":\"{\\\"header\\\":{\\\"t\\\":1},\\\"elements\\\":[{\\\"tag\\\":\\\"note\\\",\\\"elements\\\":[{\\\"tag\\\":\\\"plain_text\\\",\\\"content\\\":\\\"⚠️ 生成中断\\\"}]}]}\"}"
    }
   ],
   "result": null,
   "error": "boom",
   "config": {
    "streamThrottleMs": 1000000000,
    "streamThrottleChars": 1000000000
   }
  }
 }
}
"""##
}

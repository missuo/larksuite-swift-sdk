#!/usr/bin/env node
/*
 * Generates Swift API modules from the IR produced by extract.js.
 *
 * Usage: node generate.js <ir.json> <package-root> [project ...]
 *   With no project names, every project with methods is generated.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const [irPath, root, ...only] = process.argv.slice(2);
if (!irPath || !root) {
    console.error('usage: node generate.js <ir.json> <package-root> [project ...]');
    process.exit(1);
}
const ir = JSON.parse(fs.readFileSync(irPath, 'utf8'));

const floatFields = JSON.parse(fs.readFileSync(path.join(__dirname, 'float-fields.json'), 'utf8'));


// Public type names declared in LarkCore; generated module names must not collide with them.
function coreTypeNames(root) {
    const dir = path.join(root, 'Sources', 'LarkCore');
    const names = new Set();
    const walk = (d) => {
        for (const f of fs.readdirSync(d)) {
            const p = path.join(d, f);
            if (fs.statSync(p).isDirectory()) walk(p);
            else if (f.endsWith('.swift')) {
                for (const m of fs.readFileSync(p, 'utf8').matchAll(/public (?:final )?(?:struct|enum|class|actor|protocol|typealias) (\w+)/g)) names.add(m[1]);
            }
        }
    };
    walk(dir);
    return names;
}

const CORE_TYPES = coreTypeNames(root);

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------
const SWIFT_KEYWORDS = new Set(
    ('associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private ' +
        'precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default ' +
        'defer do else fallthrough for guard if in repeat return throw switch where while as false is nil self Self super ' +
        'throws true try any some Any Type Protocol await async').split(' ')
);
const RESERVED_TYPE_NAMES = new Set(
    ('Type Self Protocol Any Data String Int Double Float Bool Date URL Array Dictionary Set Optional Result Task Error ' +
        'Character Decoder Encoder CodingKeys CodingKey JSONValue LarkFile LarkEmpty LarkResponse Codable Sendable Never ' +
        'Void Element Index Iterator Sequence Collection Equatable Hashable Identifiable Range Substring Unicode Locale ' +
        'Calendar TimeZone Decimal UUID Notification Operation Thread Timer').split(' ')
);
const ACRONYMS = {
    im: 'IM', vc: 'VC', okr: 'OKR', acs: 'ACS', ehr: 'EHR', mdm: 'MDM', corehr: 'CoreHR', apaas: 'APaaS',
    cardkit: 'CardKit', hire: 'Hire', docx: 'Docx', aily: 'Aily', mcp: 'MCP', scim: 'SCIM', ccm: 'CCM', bi: 'BI',
    ai: 'AI', id: 'ID', kms: 'KMS', gtm: 'GTM', laps: 'LAPS', llpp: 'LLPP', authz: 'Authz', saasbi: 'SaaSBI',
    c360: 'C360', ea: 'EA', myai: 'MyAI', rag: 'RAG',
};

function words(s) {
    return String(s)
        .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
        .split(/[^A-Za-z0-9]+/)
        .filter(Boolean);
}
function pascal(s) {
    return words(s)
        .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
        .join('');
}
function camel(s) {
    const p = pascal(s);
    if (!p) return '_';
    // Keep leading acronyms lower-cased sensibly: "URL" -> "url", "IDType" stays "idType"
    let out = p.charAt(0).toLowerCase() + p.slice(1);
    if (/^[0-9]/.test(out)) out = '_' + out;
    return out;
}
function moduleShort(project) {
    return project
        .split('_')
        .map((w) => ACRONYMS[w] || w.charAt(0).toUpperCase() + w.slice(1))
        .join('');
}
/** Argument labels only need escaping for `inout`, `var` and `let`. */
function label(name) {
    return ['inout', 'var', 'let'].includes(name) ? '`' + name + '`' : name;
}
function ident(name) {
    return SWIFT_KEYWORDS.has(name) ? '`' + name + '`' : name;
}
function singular(w) {
    if (/ies$/i.test(w) && w.length > 4) return w.slice(0, -3) + 'y';
    if (/(ss|us|is)$/i.test(w)) return w;
    if (/(sses|xes|ches|shes|uses)$/i.test(w)) return w.slice(0, -2);
    if (/s$/i.test(w) && w.length > 3) return w.slice(0, -1);
    return w;
}
function typeWord(field, isArrayElement) {
    const ws = words(field);
    if (isArrayElement && ws.length) ws[ws.length - 1] = singular(ws[ws.length - 1]);
    return pascal(ws.join('_'));
}
const GENERIC = new Set(
    ('data item info result value detail content body extra config list entity record object node element option ' +
        'property field attribute param params context meta payload setting settings status i18n ext extend args').split(' ')
);

function docLines(text, indent) {
    if (!text) return [];
    return String(text)
        .split('\n')
        .map((l) => `${indent}/// ${l}`.trimEnd());
}

// ---------------------------------------------------------------------------
// Per-module type registry
// ---------------------------------------------------------------------------
class Registry {
    constructor(project) {
        this.project = project;
        this.short = moduleShort(project); // module / file naming
        // Model namespace; avoid shadowing Swift / Foundation types for `import Lark` users.
        this.ns = RESERVED_TYPE_NAMES.has(this.short) ? this.short + 'API' : this.short;
        // Fully qualified namespace for service code (resource structs may share the namespace's name).
        this.moduleName = CORE_TYPES.has(`Lark${this.short}`) ? `Lark${this.short}API` : `Lark${this.short}`;
        this.qns = `${this.moduleName}.${this.ns}`;
        this.floats = new Set(floatFields[project] || []);
        this.names = new Map(); // name -> key
        this.byKey = new Map(); // key -> name
        this.decls = []; // emitted struct/enum declarations (strings)
        this.aliases = [];
        this.structs = new Map(); // name -> props
        this.aliasTarget = new Map(); // alias -> target
        this.enums = new Map(); // name -> values
        this.tests = [];
        this.eventTests = [];
    }

    takeName(cands, key) {
        for (const c of cands) {
            if (!c || RESERVED_TYPE_NAMES.has(c) || /^[0-9]/.test(c)) continue;
            if (!this.names.has(c)) {
                this.names.set(c, key);
                return c;
            }
            if (this.names.get(c) === key) return c;
        }
        const base = cands.find((c) => c && !RESERVED_TYPE_NAMES.has(c)) || 'Model';
        for (let i = 2; ; i++) {
            const n = `${base}${i}`;
            if (!this.names.has(n)) {
                this.names.set(n, key);
                return n;
            }
        }
    }

    numberType(fieldName) {
        return this.floats.has(fieldName) ? 'Double' : 'Int';
    }

    /** Returns the Swift type expression for an IR type. */
    swiftType(t, fieldName, parentName, isArrayElement = false) {
        switch (t.kind) {
            case 'string':
                return 'String';
            case 'number':
                return this.numberType(fieldName);
            case 'boolean':
                return 'Bool';
            case 'any':
                return 'JSONValue';
            case 'file':
                return 'LarkFile';
            case 'enum':
                if (t.base === 'number') return this.numberType(fieldName);
                return this.enumType(t, fieldName, parentName);
            case 'array':
                return `[${this.swiftType(t.element, fieldName, parentName, true)}]`;
            case 'map':
                return `[String: ${this.swiftType(t.value, fieldName, parentName, true)}]`;
            case 'object': {
                if (!t.fields.length) return 'JSONValue';
                const w = typeWord(fieldName, isArrayElement);
                let cands = GENERIC.has(w.toLowerCase()) || w.length <= 2
                    ? [parentName + w]
                    : [w, parentName + w];
                // `items` of a list response are named after the resource (e.g. `Message`).
                if (['Item', 'List', 'Data'].includes(w) && this.resourceHint && /Response$/.test(parentName)) {
                    cands = [this.resourceHint, ...cands];
                }
                return this.objectType(t, cands);
            }
            default:
                return 'JSONValue';
        }
    }

    enumType(t, fieldName, parentName) {
        const values = [...t.values].map(String);
        const key = 'enum:' + JSON.stringify([...values].sort());
        if (this.byKey.has(key)) return this.byKey.get(key);
        const w = pascal(fieldName) || 'Value';
        const name = this.takeName([w, parentName + w], key);
        this.byKey.set(key, name);
        this.enums.set(name, values);
        const used = new Set();
        const members = [];
        for (const v of values) {
            let id = camel(v) || 'empty';
            if (v === '') id = 'empty';
            if (['rawValue', 'init', 'description', 'self', 'Type', 'coerce'].includes(id)) id += 'Value';
            let unique = id;
            for (let i = 2; used.has(unique); i++) unique = `${id}${i}`;
            used.add(unique);
            members.push(`        public static let ${ident(unique)}: Self = ${JSON.stringify(v)}`);
        }
        this.decls.push(
            [
                `    /// Open enumeration: unknown server values are preserved in \`rawValue\`.`,
                `    public struct ${name}: LarkOpenEnum {`,
                `        public let rawValue: String`,
                `        public init(rawValue: String) { self.rawValue = rawValue }`,
                ...members,
                `    }`,
            ].join('\n')
        );
        return name;
    }

    objectType(t, cands, alias) {
        const key = 'obj:' + JSON.stringify(t);
        if (this.byKey.has(key)) {
            const existing = this.byKey.get(key);
            if (alias && !this.names.has(alias) && !RESERVED_TYPE_NAMES.has(alias)) {
                this.names.set(alias, key + '#alias');
                this.aliases.push(`    public typealias ${alias} = ${existing}`);
                this.aliasTarget.set(alias, existing);
                return alias;
            }
            return existing;
        }
        const name = this.takeName(cands, key);
        this.byKey.set(key, name);
        // Reserve the slot so nested types are emitted after ours.
        const idx = this.decls.length;
        this.decls.push(null);
        this.decls[idx] = this.structDecl(name, t.fields);
        return name;
    }

    structDecl(name, fields, extraConformances = [], extraBody = []) {
        const props = [];
        const usedNames = new Set();
        for (const f of fields) {
            let pn = camel(f.name);
            let unique = pn;
            for (let i = 2; usedNames.has(unique); i++) unique = `${pn}${i}`;
            usedNames.add(unique);
            const ty = this.swiftType(f.type, f.name, name);
            props.push({ raw: f.name, name: unique, type: ty, optional: f.optional, irType: f.type });
        }
        const lines = [];
        lines.push(`    public struct ${name}: ${['Codable', 'Sendable', ...extraConformances].join(', ')} {`);
        for (const p of props) {
            const enumDoc = p.irType.kind === 'enum' && p.irType.base === 'number' ? ` // one of: ${p.irType.values.join(', ')}` : '';
            lines.push(`        public var ${ident(p.name)}: ${p.type}${p.optional ? '?' : ''}${enumDoc}`);
        }
        // memberwise init
        if (props.length) {
            const args = props.map((p) => `${ident(p.name)}: ${p.type}${p.optional ? '? = nil' : ''}`).join(', ');
            lines.push(`        public init(${args}) {`);
            for (const p of props) lines.push(`            self.${p.name} = ${ident(p.name)}`);
            lines.push(`        }`);
        } else {
            lines.push(`        public init() {}`);
        }
        // coding keys
        if (props.length) {
            lines.push(`        enum CodingKeys: String, CodingKey {`);
            for (const p of props) {
                lines.push(
                    p.name === p.raw
                        ? `            case ${ident(p.name)}`
                        : `            case ${ident(p.name)} = ${JSON.stringify(p.raw)}`
                );
            }
            lines.push(`        }`);
            lines.push(`        public init(from decoder: any Decoder) throws {`);
            lines.push(`            let c = try decoder.container(keyedBy: CodingKeys.self)`);
            for (const p of props) {
                lines.push(
                    p.optional
                        ? `            self.${p.name} = c.lenient(.${ident(p.name)})`
                        : `            self.${p.name} = try c.lenientRequired(.${ident(p.name)})`
                );
            }
            lines.push(`        }`);
        } else {
            lines.push(`        public init(from decoder: any Decoder) throws {}`);
            lines.push(`        public func encode(to encoder: any Encoder) throws { _ = encoder.container(keyedBy: AnyCodingKey.self) }`);
        }
        lines.push(...extraBody.map((l) => '        ' + l));
        lines.push(`    }`);
        this.structs.set(name, props);
        return { text: lines.join('\n'), props };
    }

    /** A Swift expression producing a minimal valid value of `ty` (required fields only). */
    sampleExpr(ty, depth = 0) {
        if (depth > 12) throw new Error('sample recursion too deep: ' + ty);
        switch (ty) {
            case 'String': return '"s"';
            case 'Int': return '1';
            case 'Double': return '1.5';
            case 'Bool': return 'true';
            case 'JSONValue': return '["k": "v"]';
            case 'LarkFile': return 'LarkFile(data: Data("f".utf8), fileName: "f.txt")';
            case 'LarkEmpty': return 'LarkEmpty()';
        }
        let m = ty.match(/^\[String: (.*)\]$/);
        if (m) return `["k": ${this.sampleExpr(m[1], depth + 1)}]`;
        m = ty.match(/^\[(.*)\]$/);
        if (m) return `[${this.sampleExpr(m[1], depth + 1)}]`;
        if (this.aliasTarget.has(ty)) return this.sampleExpr(this.aliasTarget.get(ty), depth);
        if (this.enums.has(ty)) return JSON.stringify(String(this.enums.get(ty)[0]));
        if (this.structs.has(ty)) {
            const args = this.structs.get(ty).filter((p) => !p.optional).map((p) => `${label(p.name)}: ${this.sampleExpr(p.type, depth + 1)}`);
            return `${this.ns}.${ty}(${args.join(', ')})`;
        }
        throw new Error('no sample for type ' + ty);
    }

    /** Top-level request/response type with a preferred exact name. */
    topLevel(t, name, versionSuffix, extraConformances = [], extraBodyFn = null) {
        if (!t || t.kind !== 'object') return null;
        if (!t.fields.length) return 'LarkEmpty';
        const shape = JSON.stringify(t);
        const nestedKey = 'obj:' + shape;
        if (!extraConformances.length && this.byKey.has(nestedKey)) {
            const existing = this.byKey.get(nestedKey);
            if (!this.names.has(name) && !RESERVED_TYPE_NAMES.has(name)) {
                this.names.set(name, nestedKey + '#alias');
                this.aliases.push(`    public typealias ${name} = ${existing}`);
                this.aliasTarget.set(name, existing);
                return name;
            }
            return existing;
        }
        const key = 'top:' + shape + (extraConformances.length ? '|' + extraConformances.join(',') : '');
        if (this.byKey.has(key)) {
            const existing = this.byKey.get(key);
            if (existing !== name && !this.names.has(name) && !RESERVED_TYPE_NAMES.has(name)) {
                this.names.set(name, key + '#alias');
                this.aliases.push(`    public typealias ${name} = ${existing}`);
                this.aliasTarget.set(name, existing);
                return name;
            }
            return existing;
        }
        const finalName = this.takeName([name, name + versionSuffix], key);
        this.byKey.set(key, finalName);
        const idx = this.decls.length;
        this.decls.push(null);
        const built = this.structDecl(finalName, t.fields, extraConformances, []);
        let text = built.text;
        if (extraBodyFn) {
            const extra = extraBodyFn(built.props);
            text = text.replace(/\n    }$/, '\n' + extra.map((l) => '        ' + l).join('\n') + '\n    }');
        }
        this.decls[idx] = text;
        this.lastProps = built.props;
        return finalName;
    }
}

// structDecl returns {text, props}; normalise for objectType.
const origObjectType = Registry.prototype.objectType;
Registry.prototype.objectType = function (t, cands, alias) {
    const key = 'obj:' + JSON.stringify(t);
    if (this.byKey.has(key)) return origObjectType.call(this, t, cands, alias);
    const name = this.takeName(cands, key);
    this.byKey.set(key, name);
    const idx = this.decls.length;
    this.decls.push(null);
    this.decls[idx] = this.structDecl(name, t.fields).text;
    return name;
};

// ---------------------------------------------------------------------------
// Method generation
// ---------------------------------------------------------------------------
function fieldsOf(payloadPart) {
    return payloadPart && payloadPart.type && payloadPart.type.kind === 'object' ? payloadPart.type.fields : [];
}
function allOptional(fields) {
    return fields.every((f) => f.optional);
}

function qual(reg, t) {
    return t === 'LarkEmpty' || t === 'JSONValue' ? t : `${reg.qns}.${t}`;
}

function genMethod(reg, m, versionSuffix) {
    const res = pascal(m.nsPath[2]);
    const meth = pascal(m.name);
    {
        const ws = words(m.nsPath[2]);
        ws[ws.length - 1] = singular(ws[ws.length - 1]);
        reg.resourceHint = pascal(ws.join('_'));
    }
    const base = `${res}${meth}`;
    const lines = [];

    // Doc comment
    const doc = m.doc || {};
    const docText = [];
    if (doc.summary) docText.push(doc.summary);
    if (doc.description) docText.push('', doc.description);
    if (doc.docUrl) docText.push('', `- SeeAlso: <${doc.docUrl}>`);
    docText.push('', `\`${m.httpMethod} ${m.path}\``);
    lines.push(...docLines(docText.join('\n'), '            '));

    const args = [];
    const callArgs = [];

    // Path parameters, in URL order.
    const pathFields = fieldsOf(m.payload.path);
    const pathNames = [...m.path.matchAll(/(?:^|\/):([^/]+)/g)].map((x) => x[1]);
    const pathArgs = pathNames.map((pn) => {
        const f = pathFields.find((x) => x.name === pn);
        const ty = f && (f.type.kind === 'number' || (f.type.kind === 'enum' && f.type.base === 'number')) ? 'Int' : 'String';
        return { raw: pn, name: camel(pn), type: ty };
    });
    for (const p of pathArgs) args.push(`${ident(p.name)}: ${p.type}`);
    let swiftPath = m.path;
    for (const p of pathArgs) {
        const v = p.type === 'String' ? `LarkURL.escapePathSegment(${ident(p.name)})` : `String(${ident(p.name)})`;
        swiftPath = swiftPath.replace(new RegExp(`(^|/):${p.raw}(?=/|$)`), `$1\\(${v})`);
    }

    // Query
    let queryType = null;
    let queryProps = null;
    const qFields = fieldsOf(m.payload.params);
    if (qFields.length) {
        queryType = reg.topLevel(m.payload.params.type, `${base}Query`, versionSuffix);
        queryProps = qFields.map((f) => ({ raw: f.name }));
        args.push(`params: ${qual(reg, queryType)}${allOptional(qFields) ? ' = .init()' : ''}`);
    }

    // Body
    let bodyType = null;
    const dFields = fieldsOf(m.payload.data);
    if (dFields.length) {
        if (m.isMultipart) {
            bodyType = reg.topLevel(m.payload.data.type, `${base}Body`, versionSuffix, ['LarkMultipartBody'], (props) => {
                const out = ['public func multipartForm() -> MultipartForm {', '    var form = MultipartForm()'];
                for (const p of props) {
                    const t = p.type;
                    const scalar = ['String', 'Int', 'Double', 'Bool', 'LarkFile'].includes(t) || /^[A-Z]\w*$/.test(t) && p.irType.kind === 'enum';
                    if (scalar) out.push(`    form.append(${JSON.stringify(p.raw)}, ${ident(p.name)})`);
                    else out.push(`    form.append(${JSON.stringify(p.raw)}, json: ${ident(p.name)})`);
                }
                out.push('    return form', '}');
                return out;
            });
        } else {
            bodyType = reg.topLevel(m.payload.data.type, `${base}Body`, versionSuffix);
        }
        args.push(`body: ${qual(reg, bodyType)}${allOptional(dFields) ? ' = .init()' : ''}`);
    }
    args.push('options: RequestOptions = .none');

    const method = `.${m.httpMethod.toLowerCase()}`;
    const httpMethod = ['get', 'post', 'put', 'patch', 'delete'].includes(m.httpMethod.toLowerCase())
        ? method
        : `HTTPMethod(rawValue: ${JSON.stringify(m.httpMethod)})`;
    const q = queryType ? 'params' : 'nil';
    const bodyExpr = bodyType ? (m.isMultipart ? '.multipart(body.multipartForm())' : '.json(body)') : '.none';
    const pathLiteral = `"${swiftPath}"`;
    const fname = ident(m.name);

    let respType = null;
    if (m.isStream) {
        lines.push(`            public func ${fname}(${args.join(', ')}) async throws -> LarkBinaryResponse {`);
        lines.push(`                try await client.download(${httpMethod}, ${pathLiteral}, query: ${q}, body: ${bodyExpr}, options: options)`);
        lines.push(`            }`);
    } else {
        const dataField = (m.response && m.response.fields || []).find((f) => f.name === 'data');
        if (!dataField || dataField.type.kind !== 'object') respType = 'JSONValue';
        else respType = reg.topLevel(dataField.type, `${base}Response`, versionSuffix) || 'JSONValue';
        lines.push(`            public func ${fname}(${args.join(', ')}) async throws -> LarkResponse<${reg.qns}.${respType}> {`);
        lines.push(`                try await client.request(${httpMethod}, ${pathLiteral}, query: ${q}, body: ${bodyExpr}, options: options)`);
        lines.push(`            }`);
        if (respType === 'JSONValue' || respType === 'LarkEmpty') {
            lines[lines.length - 3] = lines[lines.length - 3].replace(`LarkResponse<${reg.qns}.${respType}>`, `LarkResponse<${respType}>`);
        }
    }

    reg.tests.push({ m, pathArgs, queryType, bodyType, respType, qFields, dFields });

    // Pagination helper
    const t_qFields = qFields;
    if (m.paginated && queryProps && queryProps.find((p) => p.raw === 'page_token') && respType && respType !== 'JSONValue' && respType !== 'LarkEmpty') {
        const dataField = m.response.fields.find((f) => f.name === 'data');
        const dnames = dataField.type.fields.map((f) => f.name);
        const hasMore = dnames.includes('has_more') ? 'r.data?.hasMore ?? false' : 'true';
        const isNum = (f) => f && (f.type.kind === 'number' || (f.type.kind === 'enum' && f.type.base === 'number'));
        const tokenParts = [];
        for (const [raw, prop] of [['page_token', 'pageToken'], ['next_page_token', 'nextPageToken']]) {
            const f = dataField.type.fields.find((x) => x.name === raw);
            if (f) tokenParts.push(isNum(f) ? `r.data?.${prop}.map { String($0) }` : `r.data?.${prop}`);
        }
        const qTokenField = t_qFields.find((f) => f.name === 'page_token');
        const assign = isNum(qTokenField) ? 'if let token, let n = Int(token) { p.pageToken = n }' : 'if let token { p.pageToken = token }';
        const token = tokenParts.length ? tokenParts.join(' ?? ') : 'nil';
        const itArgs = args.join(', ');
        const passArgs = [
            ...pathArgs.map((p) => `${p.name}: ${ident(p.name)}`),
            'params: p',
            ...(bodyType ? ['body: body'] : []),
            'options: options',
        ].join(', ');
        const rt = `${reg.qns}.${respType}`;
        lines.push('');
        lines.push(`            /// Iterates over every page of \`${m.name}\` (equivalent of \`${m.name}WithIterator\`).`);
        lines.push(`            public func ${m.name}WithIterator(${itArgs}) -> LarkPageSequence<${rt}> {`);
        lines.push(`                LarkPageSequence { token in`);
        lines.push(`                    var p = params`);
        lines.push(`                    ${assign}`);
        lines.push(`                    let r = try await self.${fname}(${passArgs})`);
        lines.push(`                    return LarkPage(data: r.data, hasMore: ${hasMore}, nextPageToken: ${token})`);
        lines.push(`                }`);
        lines.push(`            }`);
    }
    return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
function eventsFor(project) {
    return ir.events.filter((e) => e.name.split('.')[0] === project);
}

function genEvents(reg, evs) {
    if (!evs.length) return null;
    const lines = [];
    const keys = [];
    for (const e of evs) {
        if (!e.type || e.type.kind !== 'object' || !e.type.fields.length) continue;
        const rest = e.name.split('.').slice(1).join('_');
        const typeName = reg.topLevel(e.type, pascal(rest) + 'Event', '');
        const keyName = camel(e.name);
        const doc = [e.doc && e.doc.summary, e.doc && e.doc.description].filter(Boolean).join('\n\n');
        keys.push({ keyName, typeName, name: e.name, doc });
        reg.eventTests.push({ keyName, name: e.name, sample: sampleJSON(reg, e.type, '') });
    }
    lines.push(`extension ${reg.ns} {`);
    lines.push(`    /// Event type names in this module.`);
    lines.push(`    public enum Events {`);
    for (const k of keys) {
        lines.push(...docLines(k.doc, '        '));
        const shortKey = k.name.includes('.') ? camel(k.name.split('.').slice(1).join('_')) : camel(k.name);
        lines.push(`        public static let ${ident(shortKey)} = LarkEventKey<${reg.qns}.${k.typeName}>(${JSON.stringify(k.name)})`);
    }
    lines.push(`    }`);
    lines.push(`}`);
    lines.push('');
    for (const k of keys) {
        lines.push(`extension LarkEventKey where Payload == ${reg.qns}.${k.typeName} {`);
        lines.push(...docLines(`\`${k.name}\``, '    '));
        lines.push(`    public static var ${ident(k.keyName)}: Self { .init(${JSON.stringify(k.name)}) }`);
        lines.push(`}`);
    }
    return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Project generation
// ---------------------------------------------------------------------------
function header() {
    return `// Code generated by Tools/codegen from @larksuiteoapi/node-sdk ${ir.sourceVersion}. DO NOT EDIT.\n\nimport Foundation\nimport LarkCore\n`;
}

function genProject(p) {
    const reg = new Registry(p.name);
    const ns = reg.ns;
    const short = reg.short;
    const svc = `${short}Service`;
    const versioned = p.methods.filter((m) => /^v\d+$/.test(m.nsPath[1] || ''));
    const unversioned = p.methods.filter((m) => !/^v\d+$/.test(m.nsPath[1] || ''));
    const versions = [...new Set(versioned.map((m) => m.nsPath[1]))].sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));

    // version -> resource -> methods
    const tree = new Map();
    for (const v of versions) tree.set(v, new Map());
    for (const m of versioned) {
        const r = tree.get(m.nsPath[1]);
        if (!r.has(m.nsPath[2])) r.set(m.nsPath[2], []);
        r.get(m.nsPath[2]).push(m);
    }

    const svcLines = [header()];
    svcLines.push(`extension LarkClient {`);
    svcLines.push(...docLines(`\`${p.name}\` APIs.`, '    '));
    svcLines.push(`    public var ${ident(camel(p.name))}: ${svc} { ${svc}(client: self) }`);
    svcLines.push(`}`, '');
    svcLines.push(`/// Namespace for \`${p.name}\` models.`);
    svcLines.push(`public enum ${ns} {}`, '');
    svcLines.push(`/// \`${p.name}\` APIs, grouped by version and resource.`);
    svcLines.push(`public struct ${svc}: Sendable {`);
    svcLines.push(`    public let client: LarkClient`);
    svcLines.push(`    public init(client: LarkClient) { self.client = client }`);
    for (const v of versions) svcLines.push(`    public var ${v}: ${pascal(v)} { ${pascal(v)}(client: client) }`);

    // Unversioned aliases -> the version that serves the same endpoint.
    const aliasMap = new Map();
    for (const m of unversioned) {
        const res = m.nsPath[1];
        if (aliasMap.has(res)) continue;
        const match = versioned.find((x) => x.httpMethod === m.httpMethod && x.path === m.path);
        if (match) aliasMap.set(res, { version: match.nsPath[1], resource: match.nsPath[2] });
    }
    const usedProps = new Set(versions);
    for (const [res, tgt] of aliasMap) {
        const prop = camel(res);
        if (usedProps.has(prop)) continue;
        usedProps.add(prop);
        svcLines.push(`    /// Alias of \`${tgt.version}.${camel(tgt.resource)}\`.`);
        svcLines.push(`    public var ${ident(prop)}: ${pascal(tgt.version)}.${pascal(tgt.resource)} { ${tgt.version}.${ident(camel(tgt.resource))} }`);
    }
    svcLines.push(`}`, '');

    for (const v of versions) {
        const vSuffix = versions.length > 1 ? v.toUpperCase() : '';
        svcLines.push(`extension ${svc} {`);
        svcLines.push(`    public struct ${pascal(v)}: Sendable {`);
        svcLines.push(`        public let client: LarkClient`);
        svcLines.push(`        public init(client: LarkClient) { self.client = client }`);
        for (const res of tree.get(v).keys()) {
            svcLines.push(`        public var ${ident(camel(res))}: ${pascal(res)} { ${pascal(res)}(client: client) }`);
        }
        svcLines.push(`    }`);
        svcLines.push(`}`, '');
        for (const [res, methods] of tree.get(v)) {
            svcLines.push(`extension ${svc}.${pascal(v)} {`);
            svcLines.push(`    /// \`${methods[0].meta.resource || res}\` resource.`);
            svcLines.push(`    public struct ${pascal(res)}: Sendable {`);
            svcLines.push(`        public let client: LarkClient`);
            svcLines.push(`        public init(client: LarkClient) { self.client = client }`);
            svcLines.push('');
            for (const m of methods) {
                svcLines.push(genMethod(reg, m, vSuffix).replace(/^ {12}/gm, '        '));
                svcLines.push('');
            }
            svcLines.push(`    }`);
            svcLines.push(`}`, '');
        }
    }

    const eventsText = genEvents(reg, eventsFor(p.name));

    // Models, split into chunks so the compiler can parallelise.
    const decls = [...reg.aliases, ...reg.decls.filter(Boolean)];
    const chunks = [];
    const CHUNK = 250;
    for (let i = 0; i < decls.length; i += CHUNK) chunks.push(decls.slice(i, i + CHUNK));

    const moduleName = reg.moduleName;
    const dir = path.join(root, 'Sources', moduleName);
    // Remove previously generated files only; hand-written files (without the header) are kept.
    fs.mkdirSync(dir, { recursive: true });
    for (const f of fs.readdirSync(dir)) {
        const fp = path.join(dir, f);
        if (f.endsWith('.swift') && fs.readFileSync(fp, 'utf8').startsWith('// Code generated by Tools/codegen')) fs.rmSync(fp);
    }
    fs.writeFileSync(path.join(dir, `${short}Service.swift`), svcLines.join('\n'));
    chunks.forEach((c, i) => {
        fs.writeFileSync(
            path.join(dir, `${short}Models${chunks.length > 1 ? i + 1 : ''}.swift`),
            header() + `\nextension ${ns} {\n` + c.join('\n\n') + '\n}\n'
        );
    });
    if (eventsText) fs.writeFileSync(path.join(dir, `${short}Events.swift`), header() + '\n' + eventsText + '\n');
    const testDir = path.join(root, 'Tests', `${moduleName}Tests`);
    fs.mkdirSync(testDir, { recursive: true });
    fs.writeFileSync(path.join(testDir, 'ParityHarness.swift'), HARNESS);
    fs.writeFileSync(path.join(testDir, `${short}ParityTests.swift`), genTests(reg, p));
    return { moduleName, ns, methods: versioned.length, types: decls.length };
}


// ---------------------------------------------------------------------------
// Parity tests: every method is checked against the node-sdk definition.
// ---------------------------------------------------------------------------
function sampleJSON(reg, t, field) {
    switch (t.kind) {
        case 'string': return 's';
        case 'number': return reg.floats.has(field) ? 1.5 : 1;
        case 'boolean': return true;
        case 'enum': return t.values[0];
        case 'file': return 'f';
        case 'array': return [sampleJSON(reg, t.element, field)];
        case 'map': return { k: sampleJSON(reg, t.value, field) };
        case 'object': {
            const o = {};
            for (const f of t.fields) o[f.name] = sampleJSON(reg, f.type, f.name);
            return o;
        }
        default: return { k: 'v' };
    }
}

function swiftRaw(str) {
    return `##"${str}"##`;
}

function genTests(reg, p) {
    const ns = reg.ns;
    const lines = [
        `// Code generated by Tools/codegen from @larksuiteoapi/node-sdk ${ir.sourceVersion}. DO NOT EDIT.`,
        `// Parity tests: each request must match the node-sdk definition (method, path, required`,
        `// query/body fields) and a fully populated node-sdk response must decode.`,
        '',
        'import Foundation',
        'import Testing',
        '@testable import LarkCore',
        `import ${reg.moduleName}`,
        '',
        `@Suite struct ${reg.short}ParityTests {`,
    ];
    const used = new Set();
    for (const t of reg.tests) {
        const m = t.m;
        const version = m.nsPath[1];
        let fname = `${version}_${m.nsPath[2]}_${m.name}`.replace(/[^A-Za-z0-9_]/g, '_');
        while (used.has(fname)) fname += '_';
        used.add(fname);

        const args = [];
        let expectedPath = m.path;
        for (const pa of t.pathArgs) {
            const v = pa.type === 'Int' ? '1' : 's';
            args.push(`${label(pa.name)}: ${pa.type === 'Int' ? '1' : '"s"'}`);
            expectedPath = expectedPath.replace(new RegExp(`(^|/):${pa.raw}(?=/|$)`), `$1${v}`);
        }
        if (t.queryType) args.push(`params: ${reg.sampleExpr(t.queryType)}`);
        if (t.bodyType) args.push(`body: ${reg.sampleExpr(t.bodyType)}`);
        const call = `client.${ident(camel(p.name))}.${version}.${ident(camel(m.nsPath[2]))}.${ident(m.name)}(${args.join(', ')})`;
        const reqQuery = t.qFields.filter((f) => !f.optional).map((f) => f.name);
        const reqBody = t.dFields.filter((f) => !f.optional).map((f) => f.name);

        lines.push(`    @Test(${JSON.stringify(`${m.httpMethod} ${m.path}`)}) func ${fname}() async throws {`);
        if (m.isStream) {
            lines.push(`        let (client, http) = try ParityHarness.client(binary: Data("bin".utf8))`);
            lines.push(`        let resp = try await ${call}`);
            lines.push(`        #expect(resp.data == Data("bin".utf8))`);
        } else {
            const dataField = (m.response && m.response.fields || []).find((f) => f.name === 'data');
            const sample = dataField ? sampleJSON(reg, dataField.type, 'data') : {};
            lines.push(`        let (client, http) = try ParityHarness.client(json: ${swiftRaw(JSON.stringify({ code: 0, msg: 'success', data: sample }))})`);
            lines.push(`        let resp = try await ${call}`);
            lines.push(`        #expect(resp.code == 0)`);
            if (dataField && t.respType !== 'LarkEmpty') lines.push(`        #expect(resp.data != nil)`);
        }
        lines.push(`        let req = try #require(http.apiRequest)`);
        lines.push(`        #expect(req.method.rawValue == ${JSON.stringify(m.httpMethod)})`);
        lines.push(`        #expect(ParityHarness.path(req) == ${JSON.stringify(expectedPath)})`);
        if (reqQuery.length) lines.push(`        #expect(ParityHarness.queryKeys(req).isSuperset(of: ${JSON.stringify(reqQuery)}))`);
        if (t.bodyType && m.isMultipart) {
            lines.push(`        #expect(req.headers["Content-Type"]?.hasPrefix("multipart/form-data") == true)`);
            for (const k of reqBody) lines.push(`        #expect(ParityHarness.multipartNames(req).contains(${JSON.stringify(k)}))`);
        } else if (t.bodyType) {
            lines.push(`        #expect(ParityHarness.bodyKeys(req).isSuperset(of: ${JSON.stringify(reqBody)}))`);
        } else {
            lines.push(`        #expect(req.body == nil)`);
        }
        lines.push(`    }`, '');
    }
    for (const ev of reg.eventTests) {
        let body;
        if (ev.name.includes('.')) {
            body = { schema: '2.0', header: { event_id: 'e', event_type: ev.name, create_time: '1', token: 't', app_id: 'cli_x', tenant_key: 'tk' }, event: ev.sample };
        } else {
            body = { uuid: 'u', token: 't', ts: '1', type: 'event_callback', event: { ...ev.sample, type: ev.name } };
        }
        let fname = `event_${ev.keyName}`;
        while (used.has(fname)) fname += '_';
        used.add(fname);
        lines.push(`    @Test(${JSON.stringify('event ' + ev.name)}) func ${fname}() async throws {`);
        lines.push(`        let body = try JSONValue(jsonString: ${swiftRaw(JSON.stringify(body))})`);
        lines.push(`        let dispatcher = EventDispatcher(logLevel: .fatal).register(.${ident(ev.keyName)}) { _, event in`);
        lines.push(`            JSONValue.string(event.type)`);
        lines.push(`        }`);
        lines.push(`        #expect(try await dispatcher.dispatch(json: body) == .string(${JSON.stringify(ev.name)}))`);
        lines.push(`    }`, '');
    }
    lines.push('}', '');
    return lines.join('\n');
}

const HARNESS = `// Code generated by Tools/codegen. DO NOT EDIT.
import Foundation
@testable import LarkCore

/// Mock transport used by the generated parity tests.
final class ParityHTTP: LarkHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [LarkHTTPRequest] = []
    let response: LarkHTTPResponse

    init(response: LarkHTTPResponse) { self.response = response }

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        lock.withLock { requests.append(request) }
        // The SDK's own token fetch is the only request without an Authorization header.
        if request.headers["Authorization"] == nil && request.url.path == "/open-apis/auth/v3/tenant_access_token/internal" {
            return LarkHTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":0,"tenant_access_token":"t-test","expire":7200}"#.utf8))
        }
        return response
    }

    /// The last API request (excludes the SDK's internal token fetch).
    var apiRequest: LarkHTTPRequest? {
        lock.withLock { requests.last { $0.headers["Authorization"] != nil } }
    }
}

enum ParityHarness {
    static func client(json: String) throws -> (LarkClient, ParityHTTP) {
        let http = ParityHTTP(response: LarkHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8)))
        return (try make(http), http)
    }

    static func client(binary: Data) throws -> (LarkClient, ParityHTTP) {
        let http = ParityHTTP(response: LarkHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: binary))
        return (try make(http), http)
    }

    static func make(_ http: ParityHTTP) throws -> LarkClient {
        try LarkClient(LarkConfiguration(appId: "cli_parity", appSecret: "secret", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http))
    }

    /// The raw path, keeping a trailing slash (\`URL.path\` drops it).
    static func path(_ r: LarkHTTPRequest) -> String {
        URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? r.url.path
    }

    static func queryKeys(_ r: LarkHTTPRequest) -> Set<String> {
        Set((URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\\.name))
    }

    static func bodyKeys(_ r: LarkHTTPRequest) -> Set<String> {
        guard let body = r.body, let json = try? JSONValue(data: body) else { return [] }
        return Set(json.objectValue?.keys.map { $0 } ?? [])
    }

    static func multipartNames(_ r: LarkHTTPRequest) -> Set<String> {
        guard let body = r.body else { return [] }
        let text = String(decoding: body, as: UTF8.self)
        var names = Set<String>()
        for part in text.components(separatedBy: "name=\\"").dropFirst() {
            if let end = part.firstIndex(of: "\\"") { names.insert(String(part[..<end])) }
        }
        return names
    }
}
`;

// ---------------------------------------------------------------------------
// Package.swift
// ---------------------------------------------------------------------------
function writePackage(modules) {
    const libs = modules.map((m) => `        .library(name: "${m}", targets: ["${m}"]),`).join('\n');
    const targets = modules
        .map((m) => `        .target(name: "${m}", dependencies: ["LarkCore"]),\n        .testTarget(name: "${m}Tests", dependencies: ["LarkCore", "${m}"]),`)
        .join('\n');
    const umbrellaDeps = ['LarkCore', ...modules, 'LarkChannel'].map((m) => `"${m}"`).join(', ');
    const text = `// swift-tools-version: 6.2
// Generated by Tools/codegen/generate.js (writePackage). Edit the generator, not this file.
import PackageDescription

let package = Package(
    name: "larksuite-swift-sdk",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Lark", targets: ["Lark"]),
        .library(name: "LarkCore", targets: ["LarkCore"]),
        .library(name: "LarkChannel", targets: ["LarkChannel"]),
${libs}
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "LarkCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(name: "Lark", dependencies: [${umbrellaDeps}]),
${targets}
        // Hand-written high-level modules (ports of node-sdk channel/ and scenes).
        .target(name: "LarkChannel", dependencies: ["LarkCore", "LarkIM", "LarkCardKit"]),
        .testTarget(name: "LarkChannelTests", dependencies: ["LarkCore", "LarkIM", "LarkCardKit", "LarkChannel"]),
        .executableTarget(name: "lark-bot-example", dependencies: ["LarkCore", "LarkIM"], path: "Examples/LongConnectionBot"),
        .testTarget(name: "LarkCoreTests", dependencies: ["LarkCore", "LarkIM", "LarkContact", "LarkDocx"]),
    ]
)
`;
    fs.writeFileSync(path.join(root, 'Package.swift'), text);
    const umbrella = path.join(root, 'Sources', 'Lark');
    fs.mkdirSync(umbrella, { recursive: true });
    fs.writeFileSync(
        path.join(umbrella, 'Lark.swift'),
        `// Code generated by Tools/codegen. DO NOT EDIT.\n// Umbrella module: \`import Lark\` gives access to every API module.\n\n` +
            ['LarkCore', ...modules, 'LarkChannel'].map((m) => `@_exported import ${m}`).join('\n') + '\n'
    );
}

// ---------------------------------------------------------------------------
// Events that do not belong to any API category (legacy v1 events, categories without APIs).
// ---------------------------------------------------------------------------
function allOptionalDeep(t) {
    if (t.kind === 'object') return { kind: 'object', fields: t.fields.map((f) => ({ ...f, optional: true, type: allOptionalDeep(f.type) })) };
    if (t.kind === 'array') return { kind: 'array', element: allOptionalDeep(t.element) };
    if (t.kind === 'map') return { kind: 'map', value: allOptionalDeep(t.value) };
    return t;
}

function genOtherEvents() {
    const categories = new Set(ir.projects.filter((p) => p.methods.length).map((p) => p.name));
    // Legacy (dot-less) events are hand-typed in node-sdk with every field required; the
    // platform does not guarantee that, so every field is optional here.
    const evs = ir.events
        .filter((e) => !categories.has(e.name.split('.')[0]))
        .map((e) => (e.name.includes('.') ? e : { ...e, type: allOptionalDeep(e.type) }));
    const reg = new Registry('other_events');
    reg.short = 'OtherEvents';
    reg.ns = 'OtherEvents';
    reg.moduleName = 'LarkOtherEvents';
    reg.qns = 'LarkOtherEvents.OtherEvents';
    const eventsText = genEvents(reg, evs);
    const dir = path.join(root, 'Sources', reg.moduleName);
    fs.mkdirSync(dir, { recursive: true });
    for (const f of fs.readdirSync(dir)) {
        const fp = path.join(dir, f);
        if (f.endsWith('.swift') && fs.readFileSync(fp, 'utf8').startsWith('// Code generated by Tools/codegen')) fs.rmSync(fp);
    }
    const decls = [...reg.aliases, ...reg.decls.filter(Boolean)];
    fs.writeFileSync(
        path.join(dir, 'OtherEventsModels.swift'),
        header() + `\n/// Events outside the API categories (legacy v1 events and categories without APIs).\npublic enum OtherEvents {}\n\nextension OtherEvents {\n` + decls.join('\n\n') + '\n}\n'
    );
    fs.writeFileSync(path.join(dir, 'OtherEventsEvents.swift'), header() + '\n' + eventsText + '\n');
    const testDir = path.join(root, 'Tests', `${reg.moduleName}Tests`);
    fs.mkdirSync(testDir, { recursive: true });
    fs.writeFileSync(path.join(testDir, 'ParityHarness.swift'), HARNESS);
    fs.writeFileSync(path.join(testDir, 'OtherEventsParityTests.swift'), genTests(reg, { name: 'other_events' }));
    return { moduleName: reg.moduleName, ns: reg.ns, methods: 0, types: decls.length, events: evs.length };
}

const targets = ir.projects.filter((p) => p.methods.length && (!only.length || only.includes(p.name)));
const summary = [];
for (const p of targets) {
    const r = genProject(p);
    summary.push(r);
    process.stderr.write(`${r.moduleName}: ${r.methods} methods, ${r.types} types\n`);
}
if (!only.length || only.includes('other_events')) {
    const r = genOtherEvents();
    summary.push(r);
    process.stderr.write(`${r.moduleName}: ${r.events} events, ${r.types} types\n`);
}

// Package.swift always lists every generated module present on disk.
const genFile = path.join(__dirname, 'generated-modules.json');
const previous = fs.existsSync(genFile) ? JSON.parse(fs.readFileSync(genFile, 'utf8')) : [];
const modules = [...new Set([...previous, ...summary.map((s) => s.moduleName)])]
    .filter((m) => fs.existsSync(path.join(root, 'Sources', m)))
    .sort();
fs.writeFileSync(genFile, JSON.stringify(modules, null, 1) + '\n');
writePackage(modules);

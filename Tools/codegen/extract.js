#!/usr/bin/env node
/*
 * Extracts an intermediate representation (IR) of every Open API endpoint and
 * event from the official @larksuiteoapi/node-sdk generated sources.
 *
 * Usage: node extract.js <path-to-node-sdk> <out-ir.json>
 */
'use strict';
const fs = require('fs');
const path = require('path');
const ts = require('typescript');

const sdkRoot = process.argv[2];
const outFile = process.argv[3] || path.join(__dirname, 'ir.json');
if (!sdkRoot) {
    console.error('usage: node extract.js <node-sdk-root> [out.json]');
    process.exit(1);
}

const unknownKinds = new Map();
function noteUnknown(kind, where) {
    const k = ts.SyntaxKind[kind];
    if (!unknownKinds.has(k)) unknownKinds.set(k, where);
}

// ---------------------------------------------------------------------------
// Type conversion
// ---------------------------------------------------------------------------
function propName(name) {
    if (ts.isIdentifier(name) || ts.isPrivateIdentifier(name)) return name.text;
    if (ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
    return name.getText();
}

function convertMembers(members, sf) {
    const fields = [];
    let indexValue = null;
    for (const m of members) {
        if (ts.isPropertySignature(m)) {
            fields.push({
                name: propName(m.name),
                optional: !!m.questionToken,
                type: m.type ? convertType(m.type, sf) : { kind: 'any' },
            });
        } else if (ts.isIndexSignatureDeclaration(m)) {
            indexValue = m.type ? convertType(m.type, sf) : { kind: 'any' };
        } else {
            noteUnknown(m.kind, sf.fileName);
        }
    }
    if (fields.length === 0 && indexValue) return { kind: 'map', value: indexValue };
    if (fields.length === 0) return { kind: 'object', fields: [] };
    return { kind: 'object', fields };
}

function convertType(node, sf) {
    switch (node.kind) {
        case ts.SyntaxKind.StringKeyword:
            return { kind: 'string' };
        case ts.SyntaxKind.NumberKeyword:
            return { kind: 'number' };
        case ts.SyntaxKind.BooleanKeyword:
            return { kind: 'boolean' };
        case ts.SyntaxKind.AnyKeyword:
        case ts.SyntaxKind.UnknownKeyword:
        case ts.SyntaxKind.ObjectKeyword:
            return { kind: 'any' };
        case ts.SyntaxKind.NullKeyword:
        case ts.SyntaxKind.UndefinedKeyword:
        case ts.SyntaxKind.VoidKeyword:
            return { kind: 'any' };
        case ts.SyntaxKind.ParenthesizedType:
            return convertType(node.type, sf);
        case ts.SyntaxKind.ArrayType:
            return { kind: 'array', element: convertType(node.elementType, sf) };
        case ts.SyntaxKind.TupleType: {
            const els = node.elements.map((e) => convertType(e, sf));
            return { kind: 'array', element: els[0] || { kind: 'any' } };
        }
        case ts.SyntaxKind.TypeLiteral:
            return convertMembers(node.members, sf);
        case ts.SyntaxKind.LiteralType: {
            const lit = node.literal;
            if (ts.isStringLiteral(lit)) return { kind: 'enum', base: 'string', values: [lit.text] };
            if (ts.isNumericLiteral(lit)) return { kind: 'enum', base: 'number', values: [Number(lit.text)] };
            if (lit.kind === ts.SyntaxKind.TrueKeyword || lit.kind === ts.SyntaxKind.FalseKeyword) return { kind: 'boolean' };
            if (lit.kind === ts.SyntaxKind.NullKeyword) return { kind: 'any' };
            if (ts.isPrefixUnaryExpression(lit)) return { kind: 'enum', base: 'number', values: [Number(lit.getText(sf))] };
            noteUnknown(lit.kind, sf.fileName);
            return { kind: 'any' };
        }
        case ts.SyntaxKind.UnionType: {
            const parts = node.types.map((t) => convertType(t, sf));
            if (parts.some((p) => p.kind === 'file')) return { kind: 'file' };
            const nonAny = parts.filter((p) => p.kind !== 'any');
            if (nonAny.length === 0) return { kind: 'any' };
            if (nonAny.every((p) => p.kind === 'enum' && p.base === 'string')) {
                return { kind: 'enum', base: 'string', values: [...new Set(nonAny.flatMap((p) => p.values))] };
            }
            if (nonAny.every((p) => p.kind === 'enum' && p.base === 'number')) {
                return { kind: 'enum', base: 'number', values: [...new Set(nonAny.flatMap((p) => p.values))] };
            }
            if (nonAny.length === 1) return nonAny[0];
            if (nonAny.every((p) => p.kind === 'number' || (p.kind === 'enum' && p.base === 'number'))) return { kind: 'number' };
            if (nonAny.every((p) => p.kind === 'string' || (p.kind === 'enum' && p.base === 'string'))) return { kind: 'string' };
            return { kind: 'any' };
        }
        case ts.SyntaxKind.TypeReference: {
            const name = node.typeName.getText(sf);
            const args = node.typeArguments || [];
            if (name === 'Array' || name === 'ReadonlyArray') {
                return { kind: 'array', element: args[0] ? convertType(args[0], sf) : { kind: 'any' } };
            }
            if (name === 'Record') {
                return { kind: 'map', value: args[1] ? convertType(args[1], sf) : { kind: 'any' } };
            }
            if (name === 'Buffer' || name === 'fs.ReadStream' || name === 'ReadStream' || name === 'Readable' || name === 'Blob' || name === 'File') {
                return { kind: 'file' };
            }
            if (name === 'Partial' && args[0]) return convertType(args[0], sf);
            noteUnknown(node.kind, `${sf.fileName}: ${name}`);
            return { kind: 'any' };
        }
        case ts.SyntaxKind.FunctionType:
            return { kind: 'any' };
        default:
            noteUnknown(node.kind, sf.fileName);
            return { kind: 'any' };
    }
}

// ---------------------------------------------------------------------------
// Doc comments
// ---------------------------------------------------------------------------
function leadingDoc(node, sf) {
    const text = sf.getFullText();
    const ranges = ts.getLeadingCommentRanges(text, node.getFullStart()) || [];
    const docs = ranges
        .map((r) => text.slice(r.pos, r.end))
        .filter((c) => c.startsWith('/**'));
    if (!docs.length) return null;
    const raw = docs[docs.length - 1]
        .replace(/^\/\*\*/, '')
        .replace(/\*\/$/, '')
        .split('\n')
        .map((l) => l.replace(/^\s*\* ?/, '').trimEnd());
    const lines = [];
    let docUrl = null;
    for (const l of raw) {
        const m = l.match(/\{@link (\S+) document \}/);
        if (m) {
            docUrl = m[1];
            continue;
        }
        if (/\{@link .* click to debug \}/.test(l)) continue;
        lines.push(l);
    }
    while (lines.length && !lines[0].trim()) lines.shift();
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
    const paragraphs = lines.join('\n').split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
    return {
        summary: paragraphs[0] || null,
        description: paragraphs.slice(1).join('\n\n').replace(/;;/g, '\n\n').replace(/;\n/g, '\n').replace(/。;/g, '。\n') || null,
        docUrl,
    };
}

// ---------------------------------------------------------------------------
// API method extraction
// ---------------------------------------------------------------------------
function findRequestCall(fnBody, sf) {
    // Find the `.request<..., Resp>({...})` call expression.
    let found = null;
    const visit = (n) => {
        if (found) return;
        if (
            ts.isCallExpression(n) &&
            ts.isPropertyAccessExpression(n.expression) &&
            n.expression.name.text === 'request' &&
            n.arguments.length === 1 &&
            ts.isObjectLiteralExpression(n.arguments[0])
        ) {
            found = n;
            return;
        }
        ts.forEachChild(n, visit);
    };
    visit(fnBody);
    return found;
}

function objProp(obj, name) {
    return obj.properties.find((p) => p.name && propName(p.name) === name);
}

function extractMethod(name, fn, sf, nsPath) {
    const doc = leadingDoc(fn.parent, sf);
    const call = findRequestCall(fn.body, sf);
    if (!call) throw new Error(`no request call in ${nsPath.join('.')}.${name}`);
    const cfg = call.arguments[0];

    // url
    const urlProp = objProp(cfg, 'url');
    let urlTemplate = null;
    const urlVisit = (n) => {
        if (urlTemplate) return;
        if (ts.isTemplateExpression(n) || ts.isNoSubstitutionTemplateLiteral(n)) {
            urlTemplate = n.getText(sf);
            return;
        }
        ts.forEachChild(n, urlVisit);
    };
    urlVisit(urlProp);
    const pathMatch = urlTemplate && urlTemplate.match(/\$\{this\.domain\}(\/[^`]*)`/);
    if (!pathMatch) throw new Error(`cannot parse url for ${name}: ${urlTemplate}`);
    const apiPath = pathMatch[1];

    const methodProp = objProp(cfg, 'method');
    const httpMethod = methodProp.initializer.text.toUpperCase();

    const isStream = !!objProp(cfg, 'responseType');
    let isMultipart = false;
    const headersProp = objProp(cfg, 'headers');
    if (headersProp && headersProp.getText(sf).includes('multipart/form-data')) isMultipart = true;

    // payload type
    const p0 = fn.parameters[0];
    const payload = { optional: !p0 || !!p0.questionToken };
    if (p0 && p0.type && ts.isTypeLiteralNode(p0.type)) {
        for (const m of p0.type.members) {
            if (!ts.isPropertySignature(m)) continue;
            const key = propName(m.name);
            payload[key] = {
                optional: !!m.questionToken,
                type: m.type ? convertType(m.type, sf) : { kind: 'any' },
            };
        }
    }

    let response = null;
    if (!isStream) {
        const targs = call.typeArguments || [];
        if (targs.length >= 2) {
            response = convertType(targs[1], sf);
        } else {
            response = { kind: 'any' };
        }
    }

    // version + resource from doc url query if present
    let meta = {};
    const fullDoc = sf.getFullText().slice(fn.parent.getFullStart(), fn.parent.getStart(sf));
    const dbg = fullDoc.match(/project=([\w.]+)&resource=([\w.]+)&apiName=(\w+)&version=(\w+)/);
    if (dbg) meta = { project: dbg[1], resource: dbg[2], apiName: dbg[3], version: dbg[4] };

    return {
        name,
        nsPath,
        httpMethod,
        path: apiPath,
        isStream,
        isMultipart,
        payload,
        response,
        doc,
        meta,
    };
}

function walkObject(obj, sf, nsPath, out, iterators) {
    for (const p of obj.properties) {
        if (!ts.isPropertyAssignment(p)) continue;
        const key = propName(p.name);
        const init = p.initializer;
        if (ts.isObjectLiteralExpression(init)) {
            walkObject(init, sf, [...nsPath, key], out, iterators);
        } else if (ts.isArrowFunction(init) || ts.isFunctionExpression(init)) {
            if (key.endsWith('WithIterator')) {
                iterators.add([...nsPath, key.slice(0, -'WithIterator'.length)].join('.'));
                continue;
            }
            out.push(extractMethod(key, init, sf, nsPath));
        }
    }
}

function extractProject(file) {
    const src = fs.readFileSync(file, 'utf8');
    const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const cls = sf.statements.find((s) => ts.isClassDeclaration(s));
    const methods = [];
    const iterators = new Set();
    let projectDoc = null;
    for (const m of cls.members) {
        if (!ts.isPropertyDeclaration(m) || !m.initializer || !ts.isObjectLiteralExpression(m.initializer)) continue;
        const key = propName(m.name);
        projectDoc = leadingDoc(m, sf);
        walkObject(m.initializer, sf, [key], methods, iterators);
    }
    for (const m of methods) {
        m.paginated = iterators.has([...m.nsPath, m.name].join('.'));
    }
    return { methods, doc: projectDoc };
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
function extractEvents(file) {
    const src = fs.readFileSync(file, 'utf8');
    const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const events = [];
    for (const st of sf.statements) {
        if (!ts.isInterfaceDeclaration(st)) continue;
        for (const m of st.members) {
            if (!ts.isPropertySignature(m) || !m.type || !ts.isFunctionTypeNode(m.type)) continue;
            const name = propName(m.name);
            const param = m.type.parameters[0];
            const doc = leadingDoc(m, sf);
            events.push({
                name,
                doc,
                type: param && param.type ? convertType(param.type, sf) : { kind: 'any' },
            });
        }
    }
    return events;
}

// ---------------------------------------------------------------------------
const projectsDir = path.join(sdkRoot, 'code-gen', 'projects');
const projects = [];
for (const f of fs.readdirSync(projectsDir).sort()) {
    if (!f.endsWith('.ts')) continue;
    const name = f.replace(/\.ts$/, '');
    const { methods, doc } = extractProject(path.join(projectsDir, f));
    projects.push({ name, doc, methods });
    process.stderr.write(`${name}: ${methods.length} methods\n`);
}

const events = [
    ...extractEvents(path.join(sdkRoot, 'code-gen', 'events-template.ts')),
    ...extractEvents(path.join(sdkRoot, 'code-gen', 'other-event-handles.ts')),
];

const pkg = JSON.parse(fs.readFileSync(path.join(sdkRoot, 'package.json'), 'utf8'));
fs.writeFileSync(outFile, JSON.stringify({ sourceVersion: pkg.version, projects, events }));
process.stderr.write(`events: ${events.length}\n`);
if (unknownKinds.size) {
    process.stderr.write('unknown kinds:\n');
    for (const [k, w] of unknownKinds) process.stderr.write(`  ${k} @ ${w}\n`);
}

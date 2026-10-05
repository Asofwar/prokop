"use strict";

// Minimal LuCI runtime for driving the real Prokop view modules under node.
//
// It loads luci-app-prokop/.../view/prokop/section.js (and the generated
// main.js) unchanged, builds the Rules and Settings pages from the shipped
// page/rules.js and page/settings.js (configform.js, settings.js), and
// replaces luci-base with a small model of the parts a page or modal save
// goes through: baseclass, form.Map/JSONMap/NamedSection and the
// AbstractValue family, the grid's modal Save/Dismiss, uci.js with its staged
// edits, the view's footer with Save & Apply as luci.js binds it (to the
// view, which saves the page's maps and then calls ui.changes.apply) and
// just enough DOM for the stacked item settings modal. The form code
// follows luci-base form.js of OpenWrt 24.10 and 25.12 (AbstractValue.parse,
// FlagValue.parse, Map.isDependencySatisfied, isEqual,
// AbstractSection.checkDepends, AbstractSection.formvalue,
// GridSection.cloneOptions):
//   - an inactive option is removed on save unless it sets `retain`;
//   - an active option is written only when its widget value differs from the
//     loaded cfgvalue; an active empty value is removed (rmempty);
//   - 25.12 additionally skips writes and dependency updates for fields that
//     are not rendered (every modal field is rendered here).
// Widgets are not rendered; each keeps the value its LuCI ui.* counterpart
// would report (ui.Textfield/Textarea string, ui.Checkbox enabled/disabled,
// ui.Select selected choice, ui.DynamicList item array). Like the LuCI
// validator bound to a rendered widget, a text or select widget is valid only
// while option.validate(section_id, value) returns true.

const fs = require("node:fs");
const path = require("node:path");

// PROKOP_LUCI_VIEW_DIR: another copy of the views, such as the minified one
// the package ships (tests/luci_views_minified.sh).
const VIEW_DIR =
  process.env.PROKOP_LUCI_VIEW_DIR ||
  path.join(__dirname, "../../luci-app-prokop/htdocs/luci-static/resources/view/prokop");

if (typeof String.prototype.format !== "function") {
  // LuCI extends String with printf-like format(); only %s/%d/%h are used.
  // eslint-disable-next-line no-extend-native
  String.prototype.format = function (...args) {
    let index = 0;
    return this.replace(/%[sdh]/g, () => `${args[index++]}`);
  };
}

function toArray(value) {
  if (value == null) return [];
  if (Array.isArray(value)) return value;
  if (typeof value === "object") return [value];
  const text = `${value}`.trim();
  return text === "" ? [] : text.split(/\s+/);
}

function isEqual(x, y) {
  if (typeof y === "object" && y instanceof RegExp)
    return x == null ? false : y.test(x);
  if (x != null && y != null && typeof x !== typeof y) return false;
  if ((x == null && y != null) || (x != null && y == null)) return false;
  if (Array.isArray(x)) {
    if (x.length !== y.length) return false;
    for (let i = 0; i < x.length; i++) if (!isEqual(x[i], y[i])) return false;
  } else if (typeof x === "object" && x !== null) {
    for (const k in x) {
      if (Object.hasOwn(x, k) && !Object.hasOwn(y, k)) return false;
      if (!isEqual(x[k], y[k])) return false;
    }
    for (const k in y) if (Object.hasOwn(y, k) && !Object.hasOwn(x, k)) return false;
  } else if (x != y) {
    return false;
  }
  return true;
}

// LuCI baseclass: extend(), __init__ and super(key, args).
function createBaseclass() {
  function Class() {}
  Class.prototype.super = function (key, ...rest) {
    // super(key, [args]) or super(key, arg1, arg2, ...).
    const args = rest.length === 1 && Array.isArray(rest[0]) ? rest[0] : rest;
    const chain = [];
    for (let p = Object.getPrototypeOf(this); p; p = Object.getPrototypeOf(p))
      if (Object.hasOwn(p, key)) chain.push(p[key]);
    const depth = (this.__superDepth ??= {})[key] ?? 0;
    const method = chain[depth + 1];
    if (typeof method !== "function") return method;
    this.__superDepth[key] = depth + 1;
    try {
      return method.apply(this, args);
    } finally {
      this.__superDepth[key] = depth;
    }
  };
  Class.extend = function (properties) {
    const Parent = this;
    function ClassConstructor(...args) {
      if (typeof this.__init__ === "function") this.__init__(...args);
    }
    ClassConstructor.prototype = Object.create(Parent.prototype);
    Object.defineProperties(
      ClassConstructor.prototype,
      Object.getOwnPropertyDescriptors(properties || {}),
    );
    Object.defineProperty(ClassConstructor.prototype, "constructor", {
      value: ClassConstructor,
      writable: true,
    });
    ClassConstructor.extend = Class.extend;
    return ClassConstructor;
  };
  return { Class, extend: (properties) => Class.extend(properties) };
}

function createUciStore(initial) {
  const data = JSON.parse(JSON.stringify(initial || {}));
  let counter = 0;
  const uci = {
    data,
    // luci-base uci keeps loaded packages here; settings.js reads it directly.
    state: { values: { prokop: data } },
    get(_config, sid, option) {
      const section = data[sid];
      if (!section) return null;
      if (option == null) return section;
      return section[option] ?? null;
    },
    set(_config, sid, option, value) {
      if (!data[sid]) return;
      if (value == null || (Array.isArray(value) && !value.length)) {
        delete data[sid][option];
        return;
      }
      data[sid][option] = Array.isArray(value) ? value.map(String) : `${value}`;
    },
    unset(_config, sid, option) {
      if (data[sid]) delete data[sid][option];
    },
    sections(_config, type, cb) {
      const list = Object.values(data).filter(
        (section) => type == null || section[".type"] === type,
      );
      if (typeof cb === "function") list.forEach(cb);
      return list;
    },
    add(_config, type, name) {
      const sid = name || `cfg${(++counter).toString(16).padStart(6, "0")}`;
      data[sid] = { ".name": sid, ".type": type, ".anonymous": !name };
      return sid;
    },
    remove(_config, sid) {
      delete data[sid];
    },
    load: () => Promise.resolve(),
    save: () => Promise.resolve(),
  };
  return uci;
}

function createJsonStore(object) {
  const data = {};
  for (const [sid, values] of Object.entries(object || {}))
    data[sid] = Object.assign({ ".name": sid, ".type": sid }, values);
  return createUciStore(data);
}

const clone = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

// luci-base uci.js (OpenWrt 24.10 and 25.12): state.values is the config as
// loaded; add/set/unset/remove stage edits in state.creates, state.changes and
// state.deletes until uci.save() sends them (Map.save), and the page keeps
// them until then. A form map, the rule modal included, writes here. `data`
// is the config as the next save leaves it, which the tests compare.
function createStagedUciStore(config, initial) {
  const state = {
    newidx: 0,
    values: { [config]: clone(initial || {}) },
    creates: {},
    changes: {},
    deletes: {},
    reorder: {},
    // What save() sent to rpcd and no apply has committed yet, per package
    // (the session's delta that uci.changes() reports).
    saved: {},
  };
  const stored = (value) => (Array.isArray(value) ? value.map(String) : `${value}`);
  const uci = {
    state,
    get data() {
      const result = {};
      for (const section of uci.sections(config)) {
        const view = {};
        for (const [key, value] of Object.entries(section)) {
          // rpcd drops an empty list; .create and .index are uci.js bookkeeping.
          if (key === ".create" || key === ".index") continue;
          if (Array.isArray(value) && !value.length) continue;
          view[key] = value;
        }
        result[section[".name"]] = view;
      }
      return result;
    },
    createSID(conf) {
      const v = state.values;
      const n = state.creates;
      let sid;
      do {
        sid = `new${Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0")}`;
      } while (n[conf]?.[sid] || v[conf]?.[sid]);
      return sid;
    },
    add(conf, type, name) {
      const n = state.creates;
      const sid = name || uci.createSID(conf);
      n[conf] ??= {};
      n[conf][sid] = {
        ".type": type,
        ".name": sid,
        ".create": name,
        ".anonymous": !name,
        ".index": 1000 + state.newidx++,
      };
      return sid;
    },
    remove(conf, sid) {
      const v = state.values;
      const n = state.creates;
      const c = state.changes;
      const d = state.deletes;
      if (n[conf]?.[sid]) {
        delete n[conf][sid];
      } else if (v[conf]?.[sid]) {
        delete c[conf]?.[sid];
        d[conf] ??= {};
        d[conf][sid] = true;
      }
    },
    sections(conf, type, cb) {
      const v = state.values[conf];
      const n = state.creates[conf];
      const c = state.changes[conf];
      const d = state.deletes[conf];
      const list = [];
      if (!v) return list;
      // rpcd reports .index; the fixtures keep their file order instead.
      Object.keys(v).forEach((s, position) => {
        if (d && d[s] === true) return;
        if (type && v[s][".type"] !== type) return;
        const section = Object.assign({}, v[s], c ? c[s] : null);
        if (d && d[s]) for (const opt in d[s]) delete section[opt];
        list.push([v[s][".index"] ?? position, section]);
      });
      if (n)
        for (const s in n)
          if (!type || n[s][".type"] === type) list.push([n[s][".index"], Object.assign({}, n[s])]);
      const sa = list.sort((a, b) => a[0] - b[0]).map(([, section]) => section);
      sa.forEach((section, i) => (section[".index"] = i));
      if (typeof cb === "function") sa.forEach((section) => cb.call(uci, section, section[".name"]));
      return sa;
    },
    get(conf, sid, opt) {
      const v = state.values;
      const n = state.creates;
      const c = state.changes;
      const d = state.deletes;
      if (sid == null) return null;
      if (n[conf]?.[sid]) {
        if (opt == null) return n[conf][sid];
        return n[conf][sid][opt] ?? null;
      }
      if (opt != null) {
        if (d[conf]?.[sid] && (d[conf][sid] === true || d[conf][sid][opt])) return null;
        if (c[conf]?.[sid]?.[opt] != null) return c[conf][sid][opt];
        return v[conf]?.[sid]?.[opt] ?? null;
      }
      if (!v[conf] || d[conf]?.[sid] === true) return null;
      // As uci.js does, a whole-section read merges the staged edits into the
      // loaded values in place.
      const s = v[conf][sid] || null;
      if (s) {
        if (c[conf]?.[sid])
          for (const o in c[conf][sid]) if (c[conf][sid][o] != null) s[o] = c[conf][sid][o];
        if (d[conf]?.[sid]) for (const o in d[conf][sid]) delete s[o];
      }
      return s;
    },
    set(conf, sid, opt, val) {
      const v = state.values;
      const n = state.creates;
      const c = state.changes;
      const d = state.deletes;
      if (sid == null || opt == null || opt.charAt(0) === ".") return;
      if (n[conf]?.[sid]) {
        if (val != null) n[conf][sid][opt] = stored(val);
        else delete n[conf][sid][opt];
      } else if (val != null && val !== "") {
        if (d[conf] && d[conf][sid] === true) return;
        if (!v[conf]?.[sid]) return;
        c[conf] ??= {};
        c[conf][sid] ??= {};
        if (d[conf]?.[sid]) {
          delete d[conf][sid][opt];
          if (!Object.keys(d[conf][sid]).length) delete d[conf][sid];
        }
        c[conf][sid][opt] = stored(val);
      } else {
        if (c[conf]?.[sid]) {
          delete c[conf][sid][opt];
          if (!Object.keys(c[conf][sid]).length) delete c[conf][sid];
        }
        if (Object.hasOwn(v[conf]?.[sid] ?? {}, opt)) {
          d[conf] ??= {};
          d[conf][sid] ??= {};
          if (d[conf][sid] !== true) d[conf][sid][opt] = true;
        }
      }
    },
    unset(conf, sid, opt) {
      return uci.set(conf, sid, opt, null);
    },
    load: () => Promise.resolve(),
    // rpcd's uci changes of the session ({ package: [change records] }), as
    // the header's Unsaved Changes indicator reads them.
    changes: () => Promise.resolve(clone(state.saved)),
    // What rpcd applies, reloaded: the staged edits become the loaded config.
    // libuci records no change for an option set to the value it has (a
    // Flag writes on every save); rpcd sets a list by deleting it and adding
    // its items, which it records whatever they are.
    save() {
      for (const conf of Object.keys(state.values)) {
        const changed = (sid) =>
          Object.entries(state.changes[conf][sid]).some(
            ([opt, value]) => Array.isArray(value) || `${state.values[conf][sid]?.[opt] ?? ""}` !== value,
          );
        const records = [
          ...Object.keys(state.creates[conf] ?? {}).map((sid) => ["add", sid]),
          ...Object.keys(state.changes[conf] ?? {}).filter(changed).map((sid) => ["set", sid]),
          ...Object.keys(state.deletes[conf] ?? {}).map((sid) => ["remove", sid]),
          ...Object.keys(state.reorder[conf] ?? {}).map((sid) => ["order", sid]),
        ];
        if (records.length) state.saved[conf] = [...(state.saved[conf] ?? []), ...records];
        const next = {};
        for (const section of uci.sections(conf)) {
          const { ".create": _create, ".index": _index, ...rest } = section;
          next[rest[".name"]] = rest;
        }
        state.values[conf] = next;
        delete state.creates[conf];
        delete state.changes[conf];
        delete state.deletes[conf];
        delete state.reorder[conf];
      }
      return Promise.resolve();
    },
  };
  return uci;
}

// Just enough DOM for renderStackedJsonSettingsModal and main.js top level.
class FakeNode {
  constructor(tag, attrs, children) {
    this.nodeName = `${tag || "div"}`.toUpperCase();
    this.attrs = Object.assign({}, attrs || {});
    this.childNodes = [];
    this.parentNode = null;
    this.style = {};
    const classes = new Set(`${this.attrs.class || ""}`.split(/\s+/).filter(Boolean));
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, force) =>
        (force ?? !classes.has(name)) ? classes.add(name) : classes.delete(name),
    };
    this.append(...[].concat(children ?? []));
  }
  get textContent() {
    return this.childNodes.map((node) => (typeof node === "string" ? node : node.textContent)).join("");
  }
  set textContent(value) {
    this.childNodes = value ? [`${value}`] : [];
    delete this.markup;
  }
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    return siblings[siblings.indexOf(this) + 1] || null;
  }
  append(...nodes) {
    nodes.forEach((node) => this.appendChild(node));
  }
  appendChild(node) {
    if (node == null || node === "") return node;
    if (node instanceof FakeNode) {
      if (node.parentNode) node.parentNode.removeChild(node);
      node.parentNode = this;
    }
    this.childNodes.push(node);
    return node;
  }
  insertBefore(node, reference) {
    this.appendChild(node);
    if (reference) {
      this.childNodes.pop();
      this.childNodes.splice(this.childNodes.indexOf(reference), 0, node);
    }
    return node;
  }
  removeChild(node) {
    const index = this.childNodes.indexOf(node);
    if (index >= 0) this.childNodes.splice(index, 1);
    if (node instanceof FakeNode) node.parentNode = null;
    return node;
  }
  setAttribute(name, value) {
    this.attrs[name] = `${value}`;
  }
  getAttribute(name) {
    return this.attrs[name] ?? null;
  }
  // Style sheets section.js injects into document.head.
  insertAdjacentHTML(_position, html) {
    this.childNodes.push(`${html}`);
  }
  addEventListener() {}
  removeEventListener() {}
  dispatchEvent() {
    return true;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
  querySelectorAll(selector) {
    const found = [];
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (!(child instanceof FakeNode)) continue;
        if (child.matches(selector)) found.push(child);
        walk(child);
      }
    };
    walk(this);
    return found;
  }
  matches(selector) {
    // Supports "tag", ".class", "tag.class" and ":not(.hidden)".
    const notHidden = selector.includes(":not(.hidden)");
    const [tag, ...classes] = selector.replace(":not(.hidden)", "").split(".");
    if (tag && tag.toUpperCase() !== this.nodeName) return false;
    if (!classes.every((name) => this.classList.contains(name))) return false;
    return !(notHidden && this.classList.contains("hidden"));
  }
  closest() {
    return null;
  }
}

function E(tag, attrs, children) {
  if (Array.isArray(tag)) return new FakeNode("div", {}, tag);
  if (attrs != null && (typeof attrs !== "object" || Array.isArray(attrs) || attrs instanceof FakeNode)) {
    children = attrs;
    attrs = {};
  }
  const node = new FakeNode(tag, attrs, children);
  // LuCI dom.append(): a child that is neither a node nor an array becomes
  // the node's innerHTML (array items become text nodes). The text is kept
  // as a child here; `markup` records what a browser would parse as HTML.
  if (children != null && typeof children !== "object" && typeof children !== "function")
    node.markup = `${children}`;
  return node;
}

// LuCI's page skeleton: the view renders into #view inside #maincontent
// (view.__init__, luci.js), where view.handleSave() finds the page's maps.
// Events dispatched on the document (ui.changes: "uci-applied") reach its
// listeners.
function createDocument() {
  const body = new FakeNode("body", {}, [
    new FakeNode("div", { id: "maincontent" }, [new FakeNode("div", { id: "view" })]),
  ]);
  const listeners = new Map();
  const document = {
    body,
    documentElement: body,
    head: new FakeNode("head"),
    modal: null,
    createElement: (tag) => new FakeNode(tag),
    createTextNode: (text) => `${text}`,
    getElementById(id) {
      const walk = (node) => {
        for (const child of node.childNodes) {
          if (!(child instanceof FakeNode)) continue;
          if (child.attrs.id === id) return child;
          const found = walk(child);
          if (found) return found;
        }
        return null;
      };
      return walk(body);
    },
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    removeEventListener(type, listener) {
      const list = listeners.get(type) || [];
      if (list.includes(listener)) list.splice(list.indexOf(listener), 1);
    },
    dispatchEvent(event) {
      (listeners.get(event.type) || []).slice().forEach((listener) => listener(event));
      return true;
    },
    querySelectorAll: (selector) => body.querySelectorAll(selector),
    querySelector(selector) {
      if (selector === "#modal_overlay > .modal.cbi-modal") return document.modal;
      return body.querySelector(selector);
    },
  };
  return document;
}

// The LuCI rule modal: a map with an .cbi-map, an h4 title and a button row.
function openModalShell(document) {
  const modal = E("div", { class: "modal cbi-modal" }, [
    E("h4", {}, "Rule"),
    E("div", { class: "cbi-map" }),
    E("div", { class: "button-row" }, [E("button", {}, "Dismiss"), E("button", {}, "Save")]),
  ]);
  document.modal = modal;
  return modal;
}

function createForm({ version, baseclass, uci, jsonMaps }) {
  const rendersLazily = version === "25.12";
  const AbstractElement = baseclass.Class.extend({
    __init__(title, description) {
      this.title = title || "";
      this.description = description || "";
      this.children = [];
    },
    append(child) {
      this.children.push(child);
    },
    stripTags(value) {
      return `${value || ""}`.replace(/<[^>]*>/g, "");
    },
  });

  const Map = AbstractElement.extend({
    __init__(config, title, description) {
      this.super("__init__", [title, description]);
      this.config = config;
      this.data = uci;
      this.rendered = false;
    },
    section(SectionClass, ...args) {
      const section = new SectionClass(this, ...args);
      this.append(section);
      return section;
    },
    lookupOption(name, section_id) {
      for (const section of this.children)
        for (const option of section.children)
          if (option.option === name && option.isRendered(section_id))
            return [option, section_id];
      return null;
    },
    isDependencySatisfied(depends, _config_name, section_id) {
      let def = false;
      if (!Array.isArray(depends) || !depends.length) return true;
      for (const dependency of depends) {
        let istat = true;
        const reverse = dependency["!reverse"];
        for (const dep in dependency) {
          if (dep === "!reverse" || dep === "!contains") continue;
          if (dep === "!default") {
            def = true;
            istat = false;
            continue;
          }
          const res = this.lookupOption(dep, section_id);
          const val = res && res[0].isActive(res[1]) ? res[0].formvalue(res[1]) : null;
          istat = istat && isEqual(val, dependency[dep]);
        }
        if (istat ^ Boolean(reverse)) return true;
      }
      return def;
    },
    load() {
      return Promise.all(this.children.map((section) => section.load()));
    },
    render() {
      return this.load().then(() => {
        // Map.renderContents() creates the root before the sections render
        // and binds the map to it (dom.bindClassInstance).
        this.root ??= E("div", { class: "cbi-map" });
        this.root.classInstance = this;
        this.children.forEach((section) => section.renderWidgets());
        this.rendered = true;
        this.checkDepends();
        return this.root;
      });
    },
    checkDepends(n) {
      let changed = false;
      for (const section of this.children) if (section.checkDepends()) changed = true;
      if (changed && (n ?? 0) < 10) this.checkDepends((n ?? 10) + 1);
    },
    parse() {
      return Promise.all(this.children.map((section) => section.parse()));
    },
    // Map.save(): a parse that passes sends the staged edits (uci.save).
    save() {
      this.checkDepends();
      return this.parse().then(() => this.data.save());
    },
    findElement() {
      return null;
    },
  });

  const JSONMap = Map.extend({
    __init__(data, ...args) {
      this.super("__init__", ["json", ...args]);
      this.data = createJsonStore(data);
      // Stacked item settings modals: remembered so tests can drive them.
      jsonMaps.push(this);
    },
  });

  const AbstractSection = AbstractElement.extend({
    __init__(map, sectiontype, title, description) {
      this.super("__init__", [title, description]);
      this.map = map;
      this.sectiontype = sectiontype;
      this.tabs = {};
    },
    tab(name, title) {
      this.tabs[name] = title;
    },
    option(OptionClass, ...args) {
      const option = new OptionClass(this.map, this, ...args);
      this.append(option);
      return option;
    },
    taboption(tab, OptionClass, ...args) {
      const option = this.option(OptionClass, ...args);
      option.tab = tab;
      return option;
    },
    cfgsections() {
      return [];
    },
    // AbstractSection.formvalue(section_id, option): the widget value of the
    // named child option (null when there is none), or of every child when
    // no option is named. Before the map renders it reads cfgvalue instead.
    formvalue(section_id, option) {
      const rv = arguments.length === 1 ? {} : null;
      for (const child of this.children) {
        const func = this.map.root ? child.formvalue : child.cfgvalue;
        if (rv) rv[child.option] = func.call(child, section_id);
        else if (child.option === option) return func.call(child, section_id);
      }
      return rv;
    },
    load() {
      const tasks = [];
      for (const sid of this.cfgsections())
        for (const option of this.children)
          tasks.push(
            Promise.resolve(option.load(sid)).then((value) => option.cfgvalue(sid, value)),
          );
      return Promise.all(tasks);
    },
    renderWidgets() {
      for (const sid of this.cfgsections())
        for (const option of this.children) option.renderModelWidget(sid);
    },
    checkDepends() {
      let changed = false;
      for (const sid of this.cfgsections()) {
        for (const option of this.children) {
          if (rendersLazily && !option.isRendered(sid)) continue;
          const isActive = option.isActive(sid);
          const isSatisfied = option.checkDepends(sid);
          if (isActive !== isSatisfied) {
            option.setActive(sid, isSatisfied);
            changed = true;
          }
        }
      }
      return changed;
    },
    parse() {
      const tasks = [];
      for (const sid of this.cfgsections())
        for (const option of this.children) tasks.push(option.parse(sid));
      return Promise.all(tasks);
    },
  });

  const NamedSection = AbstractSection.extend({
    __init__(map, section_id, sectiontype, ...args) {
      this.super("__init__", [map, sectiontype, ...args]);
      this.section = section_id;
    },
    cfgsections() {
      return [this.section];
    },
  });
  const TypedSection = AbstractSection.extend({
    // TypedSection.handleRemove(): remove, then save the whole map silently.
    handleRemove(section_id) {
      this.map.data.remove(this.uciconfig ?? this.map.config, section_id);
      return this.map.save(null, true);
    },
  });
  // TableSection.handleModalCancel() of a modal opened from the page: hide it.
  const hideModal = () => Promise.resolve();
  // A grid row shows a widget only for editable options (the Enable
  // checkbox); the other columns are text and the Add/Edit modal edits them.
  const isGridWidget = (option) => option.editable && !option.modalonly && !option.disable;
  const GridSection = TypedSection.extend({
    // TypedSection.cfgsections(): every UCI section of the type.
    cfgsections() {
      return this.map.data.sections(this.map.config, this.sectiontype).map((s) => s[".name"]);
    },
    // TableSection.addModalOptions(): hook called for every Add/Edit modal.
    addModalOptions() {},
    // GridSection.renderChildren().
    renderWidgets() {
      for (const sid of this.cfgsections())
        for (const option of this.children) if (isGridWidget(option)) option.renderModelWidget(sid);
    },
    // GridSection.parse(): only the row widgets are parsed.
    parse() {
      const tasks = [];
      for (const sid of this.cfgsections())
        for (const option of this.children) if (isGridWidget(option)) tasks.push(option.parse(sid));
      return Promise.all(tasks);
    },
    // TableSection.handleModalSave(): a refused save keeps the modal open.
    handleModalSave(modalMap, ev) {
      return modalMap
        .save(null, true)
        .then(() => this.handleModalCancel(modalMap, ev, true))
        .catch(() => {});
    },
    // GridSection.handleModalCancel(): Dismiss drops a rule that Add created;
    // every other edit staged while the modal was open stays in uci.
    handleModalCancel(_modalMap, _ev, isSaving) {
      if (this.map.addedSection != null && !isSaving)
        this.map.data.remove(this.uciconfig ?? this.map.config, this.map.addedSection);
      delete this.map.addedSection;
      return hideModal();
    },
  });

  class ModelWidget {
    constructor(kind, value, option, section_id) {
      this.kind = kind;
      this.option = option;
      this.section_id = section_id;
      this.setValue(value);
    }
    setValue(value) {
      const option = this.option;
      switch (this.kind) {
        case "list":
          this.value = toArray(value).map(String);
          break;
        case "checkbox":
          this.value = value == option.enabled ? option.enabled : option.disabled;
          break;
        case "select": {
          const keys = option.keylist || [];
          const optional = option.optional || option.rmempty;
          if (keys.some((key) => `${key}` === `${value ?? ""}`)) this.value = `${value}`;
          else this.value = optional ? "" : keys.length ? `${keys[0]}` : "";
          break;
        }
        default:
          this.value = value == null ? "" : Array.isArray(value) ? value.join(" ") : `${value}`;
      }
    }
    getValue() {
      return Array.isArray(this.value) ? this.value.slice() : this.value;
    }
    isChecked() {
      return this.value === this.option.enabled;
    }
    // Lists validate per item while typing. LuCI validates a checkbox with
    // the value of its <input>, which is value_enabled whether or not it is
    // checked (ui.Checkbox, validation.js); a Flag validator reads the state
    // from formvalue().
    getValidationError() {
      if (this.kind === "list") return "";
      if (typeof this.option.validate !== "function") return "";
      const value = this.kind === "checkbox" ? this.option.enabled : this.getValue();
      const result = this.option.validate(this.section_id, value);
      return result === true ? "" : `${result || "invalid"}`;
    }
    isValid() {
      return this.getValidationError() === "";
    }
    triggerValidation() {
      return this.isValid();
    }
  }

  const AbstractValue = AbstractElement.extend({
    __init__(map, section, option, ...args) {
      this.super("__init__", args);
      this.section = section;
      this.option = option;
      this.map = map;
      this.config = map.config;
      this.deps = [];
      this.initial = {};
      this.rmempty = true;
      this.default = null;
      this.size = null;
      this.optional = false;
      this.retain = false;
    },
    widgetKind: "text",
    depends(field, value) {
      this.deps.push(typeof field === "string" ? { [field]: value } : field);
    },
    value(key, value) {
      this.keylist ??= [];
      this.vallist ??= [];
      this.keylist.push(`${key}`);
      this.vallist.push(value ?? key);
    },
    transformChoices() {
      const choices = {};
      (this.keylist || []).forEach((key, i) => (choices[key] = this.vallist[i]));
      return choices;
    },
    cbid(section_id) {
      return `cbid.${this.map.config}.${section_id}.${this.option}`;
    },
    load(section_id) {
      return this.map.data.get(this.map.config, section_id, this.option);
    },
    cfgvalue(section_id, set_value) {
      if (arguments.length === 2) {
        this.data ??= {};
        this.data[section_id] = set_value;
      }
      return this.data?.[section_id];
    },
    renderModelWidget(section_id) {
      const cfgvalue = this.cfgvalue(section_id);
      this.widgets ??= {};
      this.widgets[section_id] = new ModelWidget(
        this.widgetKind,
        cfgvalue != null ? cfgvalue : this.default,
        this,
        section_id,
      );
      this.fields ??= {};
      this.fields[section_id] = { active: true };
    },
    isRendered(section_id) {
      return Boolean(this.fields?.[section_id]);
    },
    getUIElement(section_id) {
      return this.widgets?.[section_id] ?? null;
    },
    formvalue(section_id) {
      const elem = this.getUIElement(section_id);
      return elem ? elem.getValue() : null;
    },
    textvalue(section_id) {
      const value = this.cfgvalue(section_id);
      return value == null ? this.default : value;
    },
    isActive(section_id) {
      const field = this.fields?.[section_id];
      return Boolean(field && field.active);
    },
    setActive(section_id, active) {
      if (this.fields?.[section_id]) this.fields[section_id].active = active;
    },
    checkDepends(section_id) {
      return this.map.isDependencySatisfied(this.deps, this.map.config, section_id);
    },
    validate() {
      return true;
    },
    isValid(section_id) {
      const elem = this.getUIElement(section_id);
      return elem ? elem.isValid() : true;
    },
    getValidationError(section_id) {
      const elem = this.getUIElement(section_id);
      return elem ? elem.getValidationError() : "";
    },
    triggerValidation(section_id) {
      const elem = this.getUIElement(section_id);
      return elem ? elem.triggerValidation() : true;
    },
    parse(section_id) {
      const active = this.isActive(section_id);
      if (active && !this.isValid(section_id))
        return Promise.reject(
          new TypeError(
            `Option "${this.option}" contains an invalid input value. ${this.getValidationError(section_id)}`,
          ),
        );
      if (active) {
        const cval = this.cfgvalue(section_id);
        const fval = this.formvalue(section_id);
        if (fval == null || fval == "") {
          if (this.rmempty || this.optional) return Promise.resolve(this.remove(section_id));
          return Promise.reject(new TypeError(`Option "${this.option}" must not be empty.`));
        } else if (this.forcewrite || !isEqual(cval, fval)) {
          if (!rendersLazily || this.isRendered(section_id))
            return Promise.resolve(this.write(section_id, fval));
        }
      } else if (!this.retain) {
        return Promise.resolve(this.remove(section_id));
      }
      return Promise.resolve();
    },
    write(section_id, formvalue) {
      return this.map.data.set(this.map.config, section_id, this.option, formvalue);
    },
    remove(section_id) {
      this.map.data.unset(this.map.config, section_id, this.option);
    },
  });

  const Value = AbstractValue.extend({});
  // form.TextValue.renderWidget(): the field's textarea. The model does not
  // render it; tests call it to reach what section.js attaches to it.
  const TextValue = Value.extend({
    renderWidget(section_id, _option_index, cfgvalue) {
      const textarea = E("textarea", { id: this.cbid(section_id) });
      textarea.value = cfgvalue != null ? `${cfgvalue}` : "";
      return E("div", {}, [textarea]);
    },
  });
  const ListValue = Value.extend({ widgetKind: "select" });
  const DynamicList = Value.extend({ widgetKind: "list" });
  const DummyValue = Value.extend({
    widgetKind: "hidden",
    remove() {},
    write() {},
  });
  const Flag = Value.extend({
    widgetKind: "checkbox",
    __init__(...args) {
      this.super("__init__", args);
      this.enabled = "1";
      this.disabled = "0";
      this.default = this.disabled;
    },
    formvalue(section_id) {
      const elem = this.getUIElement(section_id);
      return elem && elem.isChecked() ? this.enabled : this.disabled;
    },
    parse(section_id) {
      if (this.isActive(section_id)) {
        const fval = this.formvalue(section_id);
        if (!this.isValid(section_id))
          return Promise.reject(
            new TypeError(
              `Option "${this.option}" contains an invalid input value. ${this.getValidationError(section_id)}`,
            ),
          );
        if (fval == this.default && (this.optional || this.rmempty))
          return Promise.resolve(this.remove(section_id));
        return Promise.resolve(this.write(section_id, fval));
      } else if (!this.retain) {
        return Promise.resolve(this.remove(section_id));
      }
      return Promise.resolve();
    },
  });

  // GridSection.cloneOptions(): the modal gets fresh option instances that
  // copy every own property of the grid option except the identity fields.
  // `widgets` and `fields` stand for the DOM of the map an option is rendered
  // in (LuCI finds them through map.findElement()): a modal has its own.
  function cloneOptions(src, dest) {
    for (const o1 of src.children) {
      if (o1.modalonly === false) continue;
      const o2 = dest.option(o1.constructor, o1.option, o1.title, o1.description);
      for (const k of Object.keys(o1)) {
        if (
          ["map", "section", "option", "title", "description", "subsection", "children", "widgets", "fields"].includes(k)
        )
          continue;
        o2[k] = o1[k];
      }
    }
  }

  return {
    Map,
    JSONMap,
    NamedSection,
    TypedSection,
    GridSection,
    AbstractValue,
    Value,
    TextValue,
    ListValue,
    DynamicList,
    DummyValue,
    Flag,
    cloneOptions,
  };
}

// LuCI module wrapper: "require x as y" directives, then `return <class>`.
function loadModule(file, modules, globals) {
  const source = fs.readFileSync(path.join(VIEW_DIR, file), "utf8");
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split(".").pop();
    if (!(name in modules)) throw new Error(`${file}: no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  const globalNames = Object.keys(globals);
  const exported = new Function(...names, ...globalNames, source)(
    ...values,
    ...globalNames.map((name) => globals[name]),
  );
  // LuCI instantiates a module that returns a class.
  return typeof exported === "function" ? new exported() : exported;
}

// The Prokop CLI as fs.exec answers it (createEnvironment({ fs })):
// answers[command] is the JSON the command prints, a function of its
// arguments that returns it, { code, data } for a non-zero exit, or
// { code, stdout } for raw output; other commands print {}. log gets
// "exec <arguments>" for every call.
function cliAnswers(answers, log = []) {
  return {
    exec(_command, args) {
      log.push(`exec ${args.join(" ")}`);
      let answer = answers[args[0]];
      if (typeof answer === "function") answer = answer(args);
      if (answer === undefined) return Promise.resolve({ code: 0, stdout: "{}", stderr: "" });
      if (typeof answer?.stdout === "string") return Promise.resolve({ code: answer.code ?? 0, stdout: answer.stdout, stderr: "" });
      const { code = 0, data = answer } = answer?.data !== undefined ? answer : { data: answer };
      return Promise.resolve({ code, stdout: JSON.stringify(data), stderr: "" });
    },
  };
}

// Lets pending promise chains (fs.exec answers and what follows them) run.
async function settle() {
  for (let i = 0; i < 50; i++) await new Promise((resolve) => setImmediate(resolve));
}

// Loads the real section.js for one UCI state. `version` is "24.10" or "25.12".
// `providers` is what the DPI provider availability probe reports (all
// installed by default); `fs` overrides methods of the LuCI fs stub.
function createEnvironment({
  version = "24.10",
  config = {},
  providers = { zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true },
  fs: fsOverrides = {},
  // The tab's sessionStorage; pass the previous environment's to model the
  // page load that follows a LuCI apply.
  sessionStorage = new Map(),
} = {}) {
  const baseclass = createBaseclass();
  const uci = createStagedUciStore("prokop", config);
  const document = createDocument();
  const listeners = new Map();
  // window.setTimeout callbacks wait here until runTimers() runs them.
  const timers = [];
  const notifications = [];
  const window = {
    document,
    location: { hostname: "192.168.1.1", protocol: "http:", pathname: "/" },
    navigator: { language: "en" },
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    removeEventListener(type, listener) {
      const list = listeners.get(type) || [];
      if (list.includes(listener)) list.splice(list.indexOf(listener), 1);
    },
    dispatchEvent(event) {
      (listeners.get(event.type) || []).slice().forEach((listener) => listener(event));
      return true;
    },
    setTimeout(callback) {
      timers.push(callback);
      return timers.length;
    },
    clearTimeout() {},
    setInterval: () => 0,
    clearInterval() {},
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    sessionStorage: {
      getItem: (key) => (sessionStorage.has(key) ? sessionStorage.get(key) : null),
      setItem: (key, value) => sessionStorage.set(key, `${value}`),
      removeItem: (key) => sessionStorage.delete(key),
    },
  };
  const uiAbstract = baseclass.Class.extend({
    __init__(value, choices, options) {
      this.value = value;
      this.choices = choices;
      this.options = options || {};
    },
    render: () => E("div"),
    addItem() {},
    handleClick() {},
    handleKeydown() {},
  });
  const ui = {
    // ui.DynamicList: choices maps the values offered below the list (and
    // the labels of its items) to their labels. addChoices builds each label
    // as ui.js createChoiceElement does, E("span", {}, label ?? value): a
    // string there is parsed as HTML, so it is kept in htmlChoiceLabels
    // (FE-11) and the text of the label in choices.
    DynamicList: uiAbstract.extend({
      getValue() {
        return toArray(this.value);
      },
      clearChoices() {
        this.choices = {};
      },
      addChoices(values, labels) {
        this.choices ??= {};
        this.htmlChoiceLabels ??= [];
        for (const value of values) {
          const content = E("span", {}, labels?.[value] ?? value);
          if (content.markup != null) this.htmlChoiceLabels.push(content.markup);
          this.choices[value] = content.markup ?? content.textContent;
        }
      },
    }),
    Textarea: uiAbstract.extend({}),
    Dropdown: uiAbstract.extend({}),
    Select: uiAbstract.extend({}),
    Checkbox: uiAbstract.extend({}),
    showModal() {},
    hideModal() {},
    // Recorded in notifications: { type, node, text }.
    addNotification(_title, children, ...classes) {
      const text = [].concat(children ?? []).map((node) => (typeof node === "string" ? node : node.textContent)).join("");
      notifications.push({ type: classes.join(" "), node: children, text });
    },
    tabs: { updateTabs() {} },
    // ui.changes (ui.js): apply() posts admin/uci/apply_rollback (checked) or
    // apply_unchecked and returns at once. Once rpcd confirms the apply,
    // confirm() dispatches "uci-applied" on the document and reloads the
    // page L.env.apply_display seconds later: confirmApply() below plays
    // that (it commits what uci.changes() lists, every package). applies
    // records the `checked` argument of each apply().
    changes: {
      applies: [],
      apply(checked) {
        this.applies.push(checked);
      },
    },
  };
  const jsonMaps = [];
  const form = createForm({ version, baseclass, uci, jsonMaps });
  const L = {
    bind: (fn, self, ...args) => fn.bind(self, ...args),
    toArray,
    env: { sessionid: "test" },
    resource: (...parts) => `/luci-static/resources/${parts.join("/")}`,
    isObject: (value) => value != null && typeof value === "object",
  };
  const fsStub = {
    exec: () => Promise.resolve({ code: 0, stdout: "{}", stderr: "" }),
    exec_direct: () => Promise.resolve("{}"),
    read: () => Promise.reject(new Error("ENOENT")),
    read_direct: () => Promise.reject(new Error("ENOENT")),
    stat: () => Promise.reject(new Error("ENOENT")),
    list: () => Promise.resolve([]),
    ...fsOverrides,
  };
  const globals = {
    _: (text) => `${text}`,
    N_: (_count, text) => `${text}`,
    E,
    L,
    window,
    document,
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    CustomEvent: class {
      constructor(type, init) {
        this.type = type;
        this.detail = init?.detail;
      }
    },
    requestAnimationFrame: () => 0,
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 0,
    clearInterval() {},
  };
  const rpc = { declare: () => () => Promise.resolve({}) };
  const main = loadModule("main.js", { baseclass, fs: fsStub, uci, ui, rpc }, globals);
  // dom.content() replaces the children of a node, as in LuCI.
  const dom = {
    content(node, children) {
      node.textContent = "";
      node.append(...[].concat(children ?? []));
    },
  };
  const killswitch = loadModule("killswitch.js", { baseclass, dom, fs: fsStub, ui }, globals);
  const section = loadModule(
    "section.js",
    {
      form,
      baseclass,
      fs: fsStub,
      network: { getDevices: () => Promise.resolve([]) },
      ui,
      uci,
      localDevices: { createLocalDeviceDynamicListWidget: () => E("div") },
      killswitch,
      main,
    },
    globals,
  );
  const moduleGlobals = globals;
  let settingsModule = null;
  let notificationsModule = null;
  let torrserverModule = null;
  let shellModule = null;

  // A page of the Prokop menu (page/*.js) as LuCI renders it: the view's
  // render() builds its form with configform.createMap() and renders it.
  const configform = loadModule("configform.js", { baseclass, form, uci, ui, main }, globals);

  // luci.js view of OpenWrt 24.10 and 25.12. The footer's Save & Apply is
  // bound to the view (ui.createHandlerFn(this, 'handleSaveApply')), never
  // to a form.Map, which has no handleSaveApply: handleSave() saves every
  // map of the page (dom.callClassMethod(map, 'save') for each .cbi-map in
  // #maincontent), then ui.changes.apply(mode == '0') starts the apply.
  const findClassInstance = (node) => {
    let inst = null;
    do {
      inst = node.classInstance ?? null;
      node = node.parentNode;
    } while (!inst && node != null);
    return inst;
  };
  const callClassMethod = (node, method, ...args) => {
    const inst = findClassInstance(node);
    return typeof inst?.[method] === "function" ? inst[method].call(inst, ...args) : null;
  };
  const pageMaps = () => document.getElementById("maincontent").querySelectorAll(".cbi-map");
  const view = baseclass.Class.extend({
    load() {},
    render() {},
    handleSave(_ev) {
      const tasks = [];
      pageMaps().forEach((map) => tasks.push(callClassMethod(map, "save")));
      return Promise.all(tasks);
    },
    handleSaveApply(ev, mode) {
      return this.handleSave(ev).then(() => {
        ui.changes.apply(mode == "0");
      });
    },
    handleReset(_ev) {
      const tasks = [];
      pageMaps().forEach((map) => tasks.push(callClassMethod(map, "reset")));
      return Promise.all(tasks);
    },
    // Save & Apply (a ComboButton: mode "0" Save & Apply, "1" Apply
    // unchecked), Save and Reset; disabled when every map is read-only. The
    // handler is resolved when the footer is built, as ui.createHandlerFn
    // does; here it returns the handler's promise so a test can wait for it.
    addFooter() {
      let readonly = true;
      document.getElementById("view").querySelectorAll(".cbi-map").forEach((map) => {
        const m = findClassInstance(map);
        if (m && !m.readonly) readonly = false;
      });
      const handler = (name) => {
        const fn = this[name];
        return typeof fn === "function" ? (ev, ...args) => Promise.resolve(fn.call(this, ev, ...args)) : null;
      };
      const button = (name, label) =>
        this[name] ? E("button", { class: "cbi-button", click: handler(name), disabled: readonly || null }, [label]) : "";
      return E("div", { class: "cbi-page-actions" }, [
        button("handleSaveApply", "Save & Apply"),
        button("handleSave", "Save"),
        button("handleReset", "Reset"),
      ]);
    },
  });

  // A page of the Prokop menu (page/*.js). The view is rendered here at
  // once (view.__init__ runs load() first, which only starts the shell
  // services), so a test reaches its form without waiting; mount() puts the
  // rendered content and the footer into #view, as view.__init__ does.
  function renderPage(file, modules) {
    let map = null;
    const pageConfigform = Object.create(configform, {
      createMap: { value: (...args) => (map = configform.createMap(...args)) },
    });
    const page = loadModule(file, { view, form, configform: pageConfigform, ...modules }, globals);
    const rendered = page.render();
    const mount = () =>
      Promise.resolve(rendered).then((nodes) => {
        const vp = document.getElementById("view");
        vp.childNodes.slice().forEach((node) => vp.removeChild(node));
        vp.appendChild(nodes);
        vp.appendChild(page.addFooter());
      });
    // The footer's Save & Apply (mode "0") or Apply unchecked ("1").
    const saveApply = (mode = "0") =>
      mount().then(() => {
        const vp = document.getElementById("view");
        const target = vp.querySelectorAll("button").find((node) => node.textContent === "Save & Apply");
        return target.attrs.click({ currentTarget: target }, mode);
      });
    return { map, rendered, page, mount, saveApply };
  }

  // The Rules page of page/rules.js: its map holds only the rules grid, and
  // the rule modal opens from it. shell.loadUiCapabilities is the provider
  // availability probe the page hands to section.js.
  const loadActionProvidersAvailability = () => Promise.resolve(Object.assign({}, providers));
  const rulesPage = renderPage("page/rules.js", {
    shell: { startPage: () => Promise.resolve(null), loadUiCapabilities: loadActionProvidersAvailability },
    section,
  });
  // Awaited by openRules() and openRule(); a test that only reads the grid
  // columns does not wait for the page.
  rulesPage.rendered.catch(() => {});
  const pageMap = rulesPage.map;
  const grid = pageMap.children[0];

  // The item settings modal just stacked on the modal: its Save and Close
  // buttons (`button` finds them by label) and the gears of its own lists.
  function stackedModal(button) {
    const stackedMap = jsonMaps.at(-1);
    const itemSection = stackedMap.children[0];
    const option = (name) => itemSection.children.find((o) => o.option === name);
    return {
      map: stackedMap,
      setValue(name, value) {
        option(name).getUIElement(itemSection.section).setValue(value);
      },
      save: () => button("Save").attrs.click(),
      close: () => button("Close").attrs.click(),
      // The gear of an item of a list in this modal (a priority level of a
      // priority), as the settings handler of the list widget opens it.
      async openItemSettings(optionName, itemValue, context) {
        const list = option(optionName);
        const sid = itemSection.section;
        const ownerId = list.childOwner(sid);
        await list.renderItemSettingsModal(ownerId, itemValue, list, list.getUIElement(sid), null,
          Object.assign({}, context, { parentSectionId: list.parentSection(sid), ownerId }));
        const buttons = document.modal.querySelector("div.button-row").childNodes;
        return stackedModal((label) => buttons.find((node) => node instanceof FakeNode && node.textContent === label));
      },
    };
  }

  return {
    version,
    uci,
    form,
    main,
    section,
    // notifications.js once openSettings() loaded it.
    get notificationsView() {
      return notificationsModule;
    },
    // The rules grid of the page (its row columns: grid.children).
    grid,
    document,
    window,
    CustomEvent: globals.CustomEvent,
    ui,
    // ui.addNotification() calls: { type, node, text }.
    notifications,
    // The tab's sessionStorage, for the page load after an apply.
    sessionStorage,
    // LuCI confirms the apply that ui.changes.apply() started: it
    // dispatches "uci-applied" on the document, then reloads the page
    // (createEnvironment({ sessionStorage }) is that next page).
    confirmApply() {
      for (const conf of Object.keys(uci.state.saved)) delete uci.state.saved[conf];
      document.dispatchEvent(new globals.CustomEvent("uci-applied"));
    },
    // Runs the window.setTimeout callbacks queued so far, then lets the
    // promises they start settle.
    async runTimers() {
      timers.splice(0).forEach((callback) => callback());
      await settle();
    },
    settle,
    // view/prokop/shell.js sharing this environment's main.js and window.
    shell() {
      shellModule ??= loadModule("shell.js", { baseclass, uci, main }, moduleGlobals);
      return shellModule;
    },
    // The Rules page of page/rules.js once rendered: its Save (Save & Apply
    // saves the map first), the Enable checkbox and the Delete button of a
    // rule row.
    async openRules() {
      await rulesPage.rendered;
      return {
        map: pageMap,
        grid,
        page: rulesPage.page,
        save: () => pageMap.save(),
        // The footer's Save & Apply ("0") or Apply unchecked ("1").
        saveApply: (mode) => rulesPage.saveApply(mode),
        setEnabled(section_id, value) {
          const [enabled, row] = pageMap.lookupOption("enabled", section_id);
          enabled.getUIElement(row).setValue(value);
        },
        removeRule: (section_id) => grid.handleRemove(section_id),
      };
    },
    // The Settings page of page/settings.js: the Settings tabs (one
    // "settings" section) and Components; `capabilities` is the provider
    // capabilities object (shell.uiCapabilities on the page). Components is
    // the TypeScript Components tab, which saves nothing through the form.
    async openSettings(capabilities) {
      settingsModule ??= loadModule(
        "settings.js",
        {
          form,
          uci,
          baseclass,
          killswitch,
          main,
          widgets: { DeviceSelect: form.DynamicList, NetworkSelect: form.ListValue },
        },
        moduleGlobals,
      );
      notificationsModule ??= loadModule(
        "notifications.js",
        { baseclass, form, fs: fsStub, uci, main, settings: settingsModule },
        moduleGlobals,
      );
      torrserverModule ??= loadModule(
        "torrserver.js",
        { baseclass, form, uci, main, notifications: notificationsModule },
        moduleGlobals,
      );
      const page = renderPage("page/settings.js", {
        shell: { startPage: () => Promise.resolve(null), uiCapabilities: capabilities },
        settings: settingsModule,
        notifications: notificationsModule,
        torrserver: torrserverModule,
        updates: { createUpdatesContent() {} },
      });
      await page.rendered;
      const map = page.map;
      return {
        map,
        page: page.page,
        saveApply: (mode) => page.saveApply(mode),
        option(name) {
          for (const tabSection of map.children) {
            const found = tabSection.children.find((option) => option.option === name);
            if (found) return found;
          }
          throw new Error(`settings have no option ${name}`);
        },
        save: () => map.save(),
      };
    },
    // GridSection.renderMoreOptionsModal() for an existing rule. The modal
    // map takes `readonly` from the page map (a role that may read but not
    // write the Prokop UCI package).
    async openRule(section_id, { readonly = false } = {}) {
      await rulesPage.rendered;
      const map = new form.Map("prokop");
      const named = map.section(form.NamedSection, section_id, "section");
      map.parent = pageMap;
      if (readonly) map.readonly = true;
      form.cloneOptions(grid, named);
      await grid.addModalOptions(named, section_id);
      openModalShell(document);
      await map.render();
      return {
        map,
        option(name) {
          const found = named.children.find((option) => option.option === name);
          if (!found) throw new Error(`rule modal has no option ${name}`);
          return found;
        },
        active(name) {
          return this.option(name).isActive(section_id);
        },
        save: () => map.save(),
        // The Save and Dismiss buttons of the modal (GridSection handlers).
        saveButton: () => grid.handleModalSave(map),
        dismiss: () => grid.handleModalCancel(map),
        // Clicks the gear of a DynamicList item (or its add button, with
        // context { adding: true }) and returns the stacked modal.
        async openItemSettings(optionName, itemValue, context) {
          const option = this.option(optionName);
          const widget = option.getUIElement(section_id);
          await option.renderItemSettingsModal(section_id, itemValue, option, widget, null, context);
          const buttons = document.modal.querySelector("div.button-row").childNodes;
          const button = (label) => buttons.find((node) => node instanceof FakeNode && node.textContent === label);
          return stackedModal(button);
        },
      };
    },
  };
}

module.exports = { createEnvironment, cliAnswers, isEqual, toArray };

"use strict";

(() => {
    const {
        Annotation, Decoration, EditorSelection, EditorState, EditorView, StateField, WidgetType,
        closeSearchPanel, defaultKeymap, findNext, findPrevious, keymap, openSearchPanel, search
    } = RibbonEditor;
    const markdown = window.ribbonMath.createMarkdown();
    const fromApp = Annotation.define();
    let view;
    let generation = 0;
    let waiting = false;
    let lastKey;

    function send(message) {
        return window.webkit.messageHandlers.ribbonLive.postMessage({ ...message, generation });
    }

    function equations(source, previous = new Map()) {
        const lineStarts = [0];
        for (let position = source.indexOf("\n"); position !== -1; position = source.indexOf("\n", position + 1)) {
            lineStarts.push(position + 1);
        }
        const environment = {};
        const blocks = [];
        markdown.block.parse(source, markdown, environment, blocks);
        const matches = [];
        const rendered = new Map();
        for (const block of blocks) {
            if (!block.map) continue;
            const [start, end] = block.map;
            const from = lineStarts[start];
            const to = end < lineStarts.length ? lineStarts[end] - 1 : source.length;
            if (block.type === "math_display") {
                matches.push({ from, to, source: block.content, block: true, doubled: false, editOffset: from });
            } else if (block.type === "inline" || block.type === "table_open") {
                const tokens = [];
                markdown.inline.parse(source.slice(from, to), markdown, environment, tokens);
                for (const token of tokens) {
                    if (token.type !== "math_inline") continue;
                    const { from: start, to: end, doubled, openingLength } = token.meta;
                    matches.push({ from: from + start, to: from + end, source: token.content, doubled,
                                   block: false, editOffset: from + start + openingLength });
                }
            }
        }
        for (const equation of matches) {
            const id = (equation.block ? "block:" : equation.doubled ? "display-inline:" : "inline:") + equation.source;
            let result = rendered.get(id) ?? previous.get(id);
            if (!result) {
                try {
                    result = { html: window.ribbonMath.typeset(equation.source, equation.block, equation.doubled) };
                } catch (error) {
                    if (!(error instanceof window.katex.ParseError)) throw error;
                    result = { error: error.message };
                }
            }
            rendered.set(id, result);
            equation.render = result;
        }
        matches.sort((a, b) => a.from - b.from);
        return { matches, rendered };
    }

    function decorate(document, state) {
        const ranges = window.ribbonMarkdown.decorations(document.formatting, state.selection);
        const { matches } = document;
        for (const equation of matches) {
            const { from, to, block, render } = equation;
            if (state.selection.ranges.some(range => range.empty
                ? range.head > from && range.head < to
                : range.from < to && range.to > from)) continue;
            if (render.html) {
                ranges.push(Decoration.replace({
                    widget: new EquationWidget(equation, render.html),
                    block, inclusive: false
                }).range(from, to));
            } else {
                ranges.push(Decoration.mark({
                    class: "live-equation-invalid", attributes: { title: render.error }
                }).range(from, to));
            }
        }
        return Decoration.set(ranges, true);
    }

    class EquationWidget extends WidgetType {
        constructor(equation, html) {
            super();
            this.equation = equation;
            this.html = html;
        }
        eq(other) {
            return this.equation.block === other.equation.block && this.html === other.html;
        }
        toDOM(editor) {
            const container = document.createElement(this.equation.block ? "div" : "span");
            container.className = this.equation.block ? "live-equation live-equation-block" : "live-equation";
            container.innerHTML = this.html;
            container.title = "Click to edit LaTeX";
            container.addEventListener("mousedown", event => {
                if (event.button !== 0 || event.shiftKey) return;
                event.preventDefault();
                const offset = editor.posAtDOM(container);
                const current = editor.state.field(renderingField).matches.find(equation => equation.from === offset);
                if (!current) return;
                const position = current.block ? Math.min(current.to - 1, current.from + 2) : current.editOffset;
                editor.dispatch({ selection: { anchor: position }, scrollIntoView: true });
                editor.focus();
            });
            return container;
        }
    }

    function parseDocument(state, previous) {
        const source = state.doc.toString();
        const equationsFound = equations(source, previous);
        return {
            ...equationsFound,
            formatting: window.ribbonMarkdown.formatting(state.doc, source, equationsFound.matches)
        };
    }

    const renderingField = StateField.define({
        create(state) {
            const document = parseDocument(state);
            return { ...document, decorations: decorate(document, state) };
        },
        update(value, transaction) {
            if (!transaction.docChanged && !transaction.selection) return value;
            const document = transaction.docChanged
                ? parseDocument(transaction.state, value.rendered) : value;
            return { ...document, decorations: decorate(document, transaction.state) };
        },
        provide: field => EditorView.decorations.from(field, value => value.decorations)
    });

    function range(selection) {
        return { from: selection.main.from, to: selection.main.to };
    }

    function record(update) {
        for (const transaction of update.transactions) {
            if (!transaction.docChanged || transaction.annotation(fromApp)) continue;
            const changes = [];
            transaction.changes.iterChanges((from, to, _, __, insert) => {
                changes.push({ from, to, text: insert.toString() });
            });
            send({
                kind: "edit", changes,
                before: range(transaction.startState.selection), after: range(transaction.newSelection),
                stroke: lastKey && performance.now() - lastKey.time < 160
                    && (transaction.isUserEvent("input") || transaction.isUserEvent("delete"))
                    && !transaction.isUserEvent("input.paste") ? lastKey.stroke : ""
            }).catch(console.error);
            lastKey = undefined;
        }
    }

    function setDocument(source, nextGeneration, selection) {
        if (!view || nextGeneration < generation) return;
        generation = nextGeneration;
        const anchor = Math.min(selection.from, source.length);
        const head = Math.min(selection.to, source.length);
        view.dispatch({
            changes: source === view.state.doc.toString() ? undefined : {
                from: 0, to: view.state.doc.length, insert: source
            },
            selection: EditorSelection.single(anchor, head),
            annotations: fromApp.of(true)
        });
    }

    async function command(kind) {
        if (waiting || !view) return;
        waiting = true;
        try {
            const answer = await send({ kind, selection: range(view.state.selection) });
            if (answer?.source !== undefined) setDocument(answer.source, answer.generation, answer.selection);
        } catch (error) {
            console.error(error);
        } finally {
            waiting = false;
        }
    }

    function insertMath(block) {
        if (!view || waiting) return;
        const { from, to } = range(view.state.selection);
        const doc = view.state.doc;
        const leading = block && doc.lineAt(from).from !== from ? "\n\n" : "";
        const trailing = block && doc.lineAt(to).to !== to ? "\n\n" : "";
        const opening = leading + (block ? "$$\n" : "$");
        const ending = (block ? "\n$$" : "$") + trailing;
        view.dispatch({
            changes: { from, to, insert: opening + doc.sliceString(from, to) + ending },
            selection: EditorSelection.single(from + opening.length, to + opening.length),
            userEvent: "input.ribbonMath",
            scrollIntoView: true
        });
        view.focus();
    }

    function start(source, nextGeneration, selection, fontSize) {
        if (view) {
            setDocument(source, nextGeneration, selection);
            return;
        }
        generation = nextGeneration;
        view = new EditorView({
            parent: document.getElementById("editor"),
            doc: source,
            selection: EditorSelection.single(Math.min(selection.from, source.length), Math.min(selection.to, source.length)),
            extensions: [
                renderingField,
                EditorView.lineWrapping,
                EditorView.contentAttributes.of({
                    "aria-label": "Live Markdown editor",
                    spellcheck: "false", autocapitalize: "off", autocorrect: "off"
                }),
                EditorState.changeFilter.of(transaction => !waiting || transaction.annotation(fromApp) === true),
                EditorView.updateListener.of(record),
                EditorView.domEventHandlers({
                    keydown(event) {
                        if (!event.metaKey && !event.ctrlKey && !event.isComposing) {
                            const stroke = ({ Enter: "returnKey", Backspace: "backspace", Delete: "backspace", " ": "space" })[event.key]
                                ?? (event.key.length === 1 ? "key" : "");
                            lastKey = stroke ? { stroke, time: performance.now() } : undefined;
                        }
                        return false;
                    }
                }),
                search({ top: true }),
                keymap.of([
                    { key: "Mod-z", run: () => { command("undo"); return true; } },
                    { key: "Mod-Shift-z", run: () => { command("redo"); return true; } },
                    { key: "Mod-f", run: openSearchPanel },
                    { key: "Mod-g", run: findNext },
                    { key: "Mod-Shift-g", run: findPrevious },
                    { key: "Escape", run: editor => closeSearchPanel(editor) || (command("escape"), true) },
                    ...defaultKeymap
                ])
            ]
        });
        setSize(fontSize);
    }

    function setSize(size) {
        document.documentElement.style.setProperty("--editor-size", size + "px");
    }

    window.ribbonLiveEditor = {
        start, setDocument, setSize, insertMath, command,
        focus: () => view?.focus(),
        find: action => view && ({ show: openSearchPanel, next: findNext, previous: findPrevious })[action]?.(view),
        finish: () => view ? command("leave") : Promise.resolve()
    };
})();

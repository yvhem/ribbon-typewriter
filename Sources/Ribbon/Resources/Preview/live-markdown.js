"use strict";

window.ribbonMarkdown = (() => {
    const { Decoration, GFM, markdownParser, WidgetType } = RibbonEditor;
    const parser = markdownParser.configure(GFM);
    const inlineStyles = {
        Emphasis: ["md-em", "EmphasisMark"],
        StrongEmphasis: ["md-strong", "EmphasisMark"],
        Strikethrough: ["md-strike", "StrikethroughMark"],
        InlineCode: ["md-code", "CodeMark"]
    };

    // Parse Markdown around equations using a placeholder of the same length.
    // That keeps source positions intact and keeps TeX punctuation out of Markdown.
    function withoutMath(source, equations) {
        let end = 0;
        const pieces = [];
        for (const equation of equations) {
            pieces.push(source.slice(end, equation.from));
            pieces.push(source.slice(equation.from, equation.to).replace(/[^\n]/g, equation.block ? " " : "\u037e"));
            end = equation.to;
        }
        pieces.push(source.slice(end));
        return pieces.join("");
    }

    function formatting(doc, source, equations) {
        const lineStyles = new Map();
        const spans = [];
        const markers = [];
        function addLine(position, style) {
            const classes = lineStyles.get(position) ?? new Set();
            classes.add(style);
            lineStyles.set(position, classes);
        }
        function hide(from, to, scope, bullet = false) {
            if (to > from) markers.push({ from, to, scope, bullet });
        }
        function afterSpace(position, limit) {
            const whiteSpace = /^[ \t]+/.exec(source.slice(position, limit));
            return position + (whiteSpace?.[0].length ?? 0);
        }

        parser.parse(withoutMath(source, equations)).iterate({
            enter(ref) {
                const { name, from, to, node } = ref;
                const kind = inlineStyles[name];
                if (kind) {
                    const [style, token] = kind;
                    spans.push(Decoration.mark({ class: style }).range(from, to));
                    for (const mark of node.getChildren(token)) hide(mark.from, mark.to, { from, to });
                    return;
                }

                const headingLevel = /^ATXHeading([1-6])$/.exec(name)?.[1];
                if (headingLevel) {
                    const line = doc.lineAt(from);
                    addLine(line.from, "md-heading md-h" + headingLevel);
                    const marks = node.getChildren("HeaderMark");
                    if (marks.length > 0) hide(marks[0].from, afterSpace(marks[0].to, to), line);
                    if (marks.length > 1) hide(marks[1].from, marks[1].to, line);
                    return;
                }

                if (name === "QuoteMark") {
                    const line = doc.lineAt(from);
                    addLine(line.from, "md-quote");
                    hide(from, afterSpace(to, line.to), line);
                } else if (name === "ListMark" && /^[-+*]$/.test(source.slice(from, to))) {
                    hide(from, to, doc.lineAt(from), true);
                } else if (name === "Link" && node.getChild("URL")) {
                    const [opening, closingLabel] = node.getChildren("LinkMark");
                    if (!opening || !closingLabel || closingLabel.from <= opening.to) return;
                    spans.push(Decoration.mark({ class: "md-link" }).range(opening.to, closingLabel.from));
                    hide(opening.from, opening.to, { from, to });
                    hide(closingLabel.from, to, { from, to });
                } else if (name === "HorizontalRule") {
                    const line = doc.lineAt(from);
                    addLine(line.from, "md-rule");
                    hide(from, to, line);
                } else if (name === "CodeText" && node.parent?.name === "FencedCode") {
                    spans.push(Decoration.mark({ class: "md-code-block" }).range(from, to));
                }
            }
        });

        const lines = Array.from(lineStyles, ([position, classes]) =>
            Decoration.line({ class: Array.from(classes).join(" ") }).range(position));
        return { lines, spans, markers };
    }

    class ListBullet extends WidgetType {
        eq() { return true; }
        toDOM() {
            const bullet = document.createElement("span");
            bullet.className = "md-bullet";
            bullet.textContent = "•";
            return bullet;
        }
    }

    const hideMarker = Decoration.replace({ inclusive: false });
    const replaceBullet = Decoration.replace({ widget: new ListBullet(), inclusive: false });

    function decorations(format, selection) {
        const visible = [...format.lines, ...format.spans];
        for (const { from, to, scope, bullet } of format.markers) {
            const active = selection.ranges.some(range => range.empty
                ? range.head >= scope.from && range.head <= scope.to
                : range.from < scope.to && range.to > scope.from);
            if (!active) visible.push((bullet ? replaceBullet : hideMarker).range(from, to));
        }
        return visible;
    }

    return { formatting, decorations };
})();

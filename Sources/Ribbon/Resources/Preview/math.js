"use strict";

window.ribbonMath = (() => {
    function escaped(source, offset) {
        let backslashes = 0;
        while (offset > 0 && source[--offset] === "\\") backslashes++;
        return backslashes % 2 === 1;
    }

    function inlineMath(state, silent) {
        const { src, pos, posMax } = state;
        const dollar = src[pos] === "$";
        const doubled = src.startsWith("$$", pos);
        if (!dollar && !src.startsWith("\\(", pos)) return false;

        const delimiter = doubled ? "$$" : dollar ? "$" : "\\)";
        const start = pos + delimiter.length;
        if (dollar && (src[pos - 1] === "$" || src[start] === "$"
            || (!doubled && /[\s]/.test(src[start] ?? " ")))) return false;
        const lineEnd = src.indexOf("\n", start);
        const limit = lineEnd < 0 ? posMax : Math.min(posMax, lineEnd);

        let end = src.indexOf(delimiter, start);
        while (end !== -1 && end + delimiter.length <= limit) {
            const invalidDollar = dollar && (src[end - 1] === "$" || src[end + delimiter.length] === "$"
                || (!doubled && (/\s/.test(src[end - 1]) || /\d/.test(src[end + 1] ?? ""))));
            if (!escaped(src, end) && !invalidDollar) {
                const expression = src.slice(start, end).trim();
                if (!expression) return false;
                if (!silent) {
                    const token = state.push("math_inline", "math", 0);
                    token.content = expression;
                    token.meta = { from: pos, to: end + delimiter.length, doubled, openingLength: delimiter.length };
                }
                state.pos = end + delimiter.length;
                return true;
            }
            end = src.indexOf(delimiter, end + delimiter.length);
        }
        return false;
    }

    function displayMath(state, startLine, endLine, silent) {
        if (state.sCount[startLine] - state.blkIndent >= 4) return false;
        const firstLine = state.src.slice(state.bMarks[startLine] + state.tShift[startLine], state.eMarks[startLine]);
        const opening = firstLine.slice(0, 2);
        if (opening !== "$$" && opening !== "\\[") return false;

        const closing = opening === "$$" ? "$$" : "\\]";
        const lines = [];
        for (let line = startLine; line < endLine; line++) {
            if (line > startLine && state.sCount[line] < state.blkIndent && !state.isEmpty(line)) break;
            const part = line === startLine
                ? firstLine.slice(2)
                : state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
            const trimmed = part.trimEnd();
            const closeIndex = trimmed.length - closing.length;
            if (trimmed.endsWith(closing) && !escaped(trimmed, closeIndex)) {
                lines.push(trimmed.slice(0, closeIndex));
                const expression = lines.join("\n").trim();
                if (!expression) return false;
                if (silent) return true;
                const token = state.push("math_display", "math", 0);
                token.block = true;
                token.map = [startLine, line + 1];
                token.content = expression;
                state.line = line + 1;
                return true;
            }
            lines.push(part);
        }
        return false;
    }

    function typeset(source, displayMode, doubled = false) {
        return window.katex.renderToString(doubled ? "\\displaystyle " + source : source, {
            displayMode, trust: false, strict: "ignore", maxExpand: 500, maxSize: 20
        });
    }

    function renderMath(markdown, source, displayMode, doubled) {
        try {
            return typeset(source, displayMode, doubled);
        } catch (error) {
            if (!(error instanceof window.katex.ParseError)) throw error;
            const element = displayMode ? "pre" : "code";
            const escape = markdown.utils.escapeHtml;
            return "<" + element + ' class="math-error" title="' + escape(error.message) + '">'
                + escape(source) + "</" + element + ">";
        }
    }

    function createMarkdown() {
        const markdown = window.markdownit({ html: false, linkify: false });
        markdown.inline.ruler.before("escape", "math_inline", inlineMath);
        markdown.block.ruler.before("fence", "math_display", displayMath, {
            alt: ["paragraph", "reference", "blockquote", "list"]
        });
        markdown.renderer.rules.math_inline = (tokens, index) => renderMath(markdown, tokens[index].content, false, tokens[index].meta.doubled);
        markdown.renderer.rules.math_display = (tokens, index) => renderMath(markdown, tokens[index].content, true) + "\n";
        markdown.renderer.rules.image = (tokens, index, options, env, renderer) => {
            const description = renderer.renderInlineAsText(tokens[index].children, options, env);
            return '<span class="image-caption">' + markdown.utils.escapeHtml(description || "Image") + "</span>";
        };

        return markdown;
    }

    return { createMarkdown, typeset };
})();

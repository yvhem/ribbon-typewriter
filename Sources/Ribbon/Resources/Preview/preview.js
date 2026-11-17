"use strict";

const markdown = window.ribbonMath.createMarkdown();
const pane = document.getElementById("document");

window.renderMarkdown = (source) => {
    pane.innerHTML = source.trim()
        ? markdown.render(source)
        : '<p class="empty">Your preview appears here as you write.</p>';
};

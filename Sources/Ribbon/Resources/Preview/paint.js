"use strict";

window.ribbonWaitForPaint = () => Promise.race([
    (async () => {
        document.documentElement.getBoundingClientRect();
        await document.fonts.ready;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    })(),
    // A hidden WebKit view may throttle frame callbacks while its first layout is prepared.
    new Promise(resolve => setTimeout(resolve, 110))
]);

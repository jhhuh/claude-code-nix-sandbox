(function () {
  "use strict";

  var output = document.getElementById("log-output");
  var status = document.getElementById("log-status");
  if (!output) return;

  var sandboxId = output.dataset.sandboxId;
  if (!sandboxId) return;

  var ws = null;
  var retryDelay = 1000;
  var maxRetryDelay = 30000;
  var autoScroll = true;

  // Detect if user scrolled up (disable auto-scroll)
  output.addEventListener("scroll", function () {
    var atBottom =
      output.scrollHeight - output.scrollTop - output.clientHeight < 50;
    autoScroll = atBottom;
  });

  function setStatus(text, color) {
    if (status) {
      status.textContent = text;
      status.style.color = color || "inherit";
    }
  }

  function scrollToBottom() {
    if (autoScroll) {
      output.scrollTop = output.scrollHeight;
    }
  }

  function connect() {
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    var url = proto + "//" + location.host + "/ws/sandboxes/" + sandboxId + "/logs";

    setStatus("connecting...", "var(--yellow)");
    ws = new WebSocket(url);

    ws.onopen = function () {
      setStatus("connected", "var(--green)");
      retryDelay = 1000;
    };

    ws.onmessage = function (e) {
      output.textContent += e.data;
      scrollToBottom();
    };

    ws.onclose = function () {
      setStatus("disconnected — retrying in " + (retryDelay / 1000) + "s", "var(--muted)");
      setTimeout(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, maxRetryDelay);
    };

    ws.onerror = function () {
      ws.close();
    };
  }

  connect();
})();

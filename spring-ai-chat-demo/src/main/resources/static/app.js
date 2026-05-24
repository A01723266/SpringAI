const form = document.querySelector("#chatForm");
const input = document.querySelector("#promptInput");
const sendButton = document.querySelector("#sendButton");
const clearButton = document.querySelector("#clearButton");
const messages = document.querySelector("#messages");
const loading = document.querySelector("#loading");
const errorBox = document.querySelector("#errorBox");

function setBusy(isBusy) {
  loading.hidden = !isBusy;
  sendButton.disabled = isBusy;
  input.disabled = isBusy;
}

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = false;
}

function clearError() {
  errorBox.textContent = "";
  errorBox.hidden = true;
}

function addMessage(role, text) {
  const item = document.createElement("article");
  item.className = `message ${role}`;

  const label = document.createElement("span");
  label.className = "role";
  label.textContent = role === "user" ? "Tu" : "Ollama";

  const body = document.createElement("div");
  body.textContent = text;

  item.append(label, body);
  messages.appendChild(item);
  messages.scrollTop = messages.scrollHeight;
}

async function sendPrompt(prompt) {
  const response = await fetch("/api/chat", {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ prompt })
  });

  const payload = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(payload.message || "No se pudo completar la solicitud.");
  }

  return payload.response || "";
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  clearError();

  const prompt = input.value.trim();
  if (!prompt) {
    showError("Escribe un mensaje antes de enviar.");
    input.focus();
    return;
  }

  addMessage("user", prompt);
  input.value = "";
  setBusy(true);

  try {
    const answer = await sendPrompt(prompt);
    addMessage("assistant", answer || "(Sin contenido)");
  }
  catch (error) {
    showError(error.message);
  }
  finally {
    setBusy(false);
    input.focus();
  }
});

clearButton.addEventListener("click", () => {
  messages.replaceChildren();
  clearError();
  input.focus();
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});

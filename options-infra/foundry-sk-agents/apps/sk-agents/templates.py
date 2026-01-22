"""
HTML templates for the SK Agents web UI.
"""


def get_ui_html() -> str:
    """Return the HTML for the simple web UI."""
    return """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SK Agents - Master Agent Interface</title>
    <style>
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            color: #fff;
            padding: 20px;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
        }
        header {
            text-align: center;
            margin-bottom: 30px;
        }
        h1 {
            color: #00d9ff;
            margin-bottom: 10px;
        }
        .subtitle {
            color: #888;
            font-size: 14px;
        }
        .chat-container {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 20px;
        }
        #messages {
            height: 400px;
            overflow-y: auto;
            margin-bottom: 20px;
            padding: 15px;
            background: rgba(0, 0, 0, 0.3);
            border-radius: 8px;
        }
        .message {
            margin-bottom: 15px;
            padding: 12px 15px;
            border-radius: 8px;
            max-width: 85%;
        }
        .message.user {
            background: #0078d4;
            margin-left: auto;
        }
        .message.agent {
            background: rgba(255, 255, 255, 0.1);
            border-left: 3px solid #00d9ff;
        }
        .message .meta {
            font-size: 11px;
            color: #888;
            margin-top: 8px;
        }
        .input-container {
            display: flex;
            gap: 10px;
        }
        #userInput {
            flex: 1;
            padding: 15px;
            border: none;
            border-radius: 8px;
            background: rgba(255, 255, 255, 0.1);
            color: #fff;
            font-size: 14px;
        }
        #userInput:focus {
            outline: 2px solid #00d9ff;
        }
        #userInput::placeholder {
            color: #666;
        }
        button {
            padding: 15px 30px;
            border: none;
            border-radius: 8px;
            background: #0078d4;
            color: #fff;
            cursor: pointer;
            font-size: 14px;
            transition: background 0.3s;
        }
        button:hover {
            background: #005a9e;
        }
        button:disabled {
            background: #444;
            cursor: not-allowed;
        }
        .status {
            text-align: center;
            padding: 10px;
            background: rgba(0, 217, 255, 0.1);
            border-radius: 8px;
            font-size: 12px;
            color: #00d9ff;
        }
        .loading {
            display: none;
            text-align: center;
            padding: 20px;
        }
        .loading.show {
            display: block;
        }
        .spinner {
            border: 3px solid rgba(255, 255, 255, 0.1);
            border-top: 3px solid #00d9ff;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 1s linear infinite;
            margin: 0 auto 10px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .examples {
            margin-top: 20px;
            padding: 15px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
        }
        .examples h3 {
            color: #00d9ff;
            margin-bottom: 10px;
            font-size: 14px;
        }
        .example-btn {
            display: inline-block;
            padding: 8px 12px;
            margin: 5px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 5px;
            cursor: pointer;
            font-size: 12px;
            transition: background 0.3s;
        }
        .example-btn:hover {
            background: rgba(255, 255, 255, 0.2);
        }
        pre {
            background: rgba(0, 0, 0, 0.3);
            padding: 10px;
            border-radius: 5px;
            overflow-x: auto;
            font-size: 12px;
            margin-top: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🤖 Master Agent Interface</h1>
            <p class="subtitle">Powered by Semantic Kernel & Azure AI Foundry</p>
        </header>
        
        <div class="chat-container">
            <div id="messages">
                <div class="message agent">
                    <strong>Master Agent</strong>
                    <p>Hello! I'm the Master Agent. I can help you with various tasks by orchestrating specialized agents and plugins. Try asking me to:</p>
                    <ul style="margin-top: 10px; margin-left: 20px;">
                        <li>Summarize files (I'll delegate to the Large Context Agent)</li>
                        <li>Answer questions using my knowledge plugins</li>
                        <li>Process and analyze data</li>
                    </ul>
                </div>
            </div>
            
            <div class="loading" id="loading">
                <div class="spinner"></div>
                <p>Processing your request...</p>
            </div>
            
            <div class="input-container">
                <input type="text" id="userInput" placeholder="Type your message here..." onkeypress="handleKeyPress(event)">
                <button onclick="sendMessage()" id="sendBtn">Send</button>
            </div>
        </div>
        
        <div class="examples">
            <h3>💡 Example Prompts</h3>
            <span class="example-btn" onclick="setExample('Summarize the following files: report.pdf, analysis.docx, data.csv')">Summarize files</span>
            <span class="example-btn" onclick="setExample('What can you help me with?')">Capabilities</span>
            <span class="example-btn" onclick="setExample('Process the quarterly reports from Q1 to Q4')">Process reports</span>
            <span class="example-btn" onclick="setExample('Analyze the project documentation')">Analyze docs</span>
        </div>
        
        <div class="status" id="status">
            Checking agent status...
        </div>
    </div>
    
    <script>
        const messagesEl = document.getElementById('messages');
        const inputEl = document.getElementById('userInput');
        const loadingEl = document.getElementById('loading');
        const sendBtn = document.getElementById('sendBtn');
        const statusEl = document.getElementById('status');
        
        // Check health on load
        checkHealth();
        
        async function checkHealth() {
            try {
                const response = await fetch('/health');
                const data = await response.json();
                if (data.agents_initialized) {
                    statusEl.textContent = '✅ Agents initialized and ready';
                    statusEl.style.background = 'rgba(0, 255, 100, 0.1)';
                    statusEl.style.color = '#00ff64';
                } else {
                    statusEl.textContent = '⏳ Agents initializing...';
                }
            } catch (error) {
                statusEl.textContent = '❌ Error connecting to service';
                statusEl.style.background = 'rgba(255, 0, 0, 0.1)';
                statusEl.style.color = '#ff6464';
            }
        }
        
        function setExample(text) {
            inputEl.value = text;
            inputEl.focus();
        }
        
        function handleKeyPress(event) {
            if (event.key === 'Enter') {
                sendMessage();
            }
        }
        
        function addMessage(content, isUser, meta = null) {
            const div = document.createElement('div');
            div.className = `message ${isUser ? 'user' : 'agent'}`;
            
            let html = '';
            if (!isUser) {
                html += '<strong>Master Agent</strong><br>';
            }
            html += `<p>${content.replace(/\\n/g, '<br>')}</p>`;
            
            if (meta) {
                html += `<div class="meta">`;
                if (meta.agent_used) {
                    html += `Agent: ${meta.agent_used} | `;
                }
                if (meta.plugins_invoked && meta.plugins_invoked.length > 0) {
                    html += `Plugins: ${meta.plugins_invoked.join(', ')}`;
                }
                html += `</div>`;
            }
            
            div.innerHTML = html;
            messagesEl.appendChild(div);
            messagesEl.scrollTop = messagesEl.scrollHeight;
        }
        
        async function sendMessage() {
            const message = inputEl.value.trim();
            if (!message) return;
            
            // Add user message
            addMessage(message, true);
            inputEl.value = '';
            
            // Show loading
            loadingEl.classList.add('show');
            sendBtn.disabled = true;
            
            try {
                const response = await fetch('/invoke', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ message })
                });
                
                if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                }
                
                const data = await response.json();
                addMessage(data.response, false, {
                    agent_used: data.agent_used,
                    plugins_invoked: data.plugins_invoked
                });
                
            } catch (error) {
                addMessage(`Error: ${error.message}. Please try again.`, false);
            } finally {
                loadingEl.classList.remove('show');
                sendBtn.disabled = false;
            }
        }
    </script>
</body>
</html>
"""

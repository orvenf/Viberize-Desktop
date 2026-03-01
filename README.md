# Viberize Desktop – Automated Build Scripts

This repository contains a set of PowerShell scripts (1–7) that fully automate the build process of **Viberize Desktop**, an offline‑first AI desktop application.  
The app is built with:

- **React** (TypeScript) + **Vite** for the frontend
- **Tauri** + **Rust** for the backend (lightweight, secure)
- **Ollama** as the local LLM engine (no internet required)

These scripts are designed to run on a **fresh Windows 10/11** machine and will install all necessary tools, scaffold the source code, install dependencies, build the frontend and backend, and finally verify the output.

---

## 📁 Scripts Overview

| Script | Purpose |
|--------|---------|
| `1-Audit.ps1` | Read‑only system audit – checks for prerequisites (Node.js, Rust, disk space, etc.). |
| `2-Install-Prerequisites.ps1` | Installs all required tools: Node.js, Rust, Tauri CLI, WebView2, VC++ Redist, Ollama, etc. |
| `3-Scaffold-Source.ps1` | Writes all frontend (React) and backend (Rust) source files into the `app` directory. |
| `4-Install-Dependencies.ps1` | Runs `npm install` (offline‑first) and `cargo fetch` to download project dependencies. |
| `5-Build-Frontend.ps1` | TypeScript check + Vite production build – produces `dist/` folder. |
| `6-Build-Backend.ps1` | Rust check + Tauri release build – generates `.exe` and `.msi` installer. |
| `7-Verify.ps1` | Post‑build health check – validates artifacts, Ollama, fonts, and configuration. |

---

## 🚀 How to Use

1. **Clone or download** this repository to your Windows machine.  
2. **Open PowerShell as Administrator** (right‑click → Run as Administrator).  
3. Navigate to the folder containing the scripts.  
4. Run the scripts **in order** by typing their names, for example:  
   ```powershell
   .\1-Audit.ps1
   .\2-Install-Prerequisites.ps1
   .\3-Scaffold-Source.ps1
   .\4-Install-Dependencies.ps1
   .\5-Build-Frontend.ps1
   .\6-Build-Backend.ps1
   .\7-Verify.ps1
   ```
5. Each script is **re‑runnable** – if a step fails, you can fix the issue and run it again without starting over.

---

## 📦 Requirements

- **Operating System**: Windows 10/11 (64‑bit)
- **Disk Space**: At least 20 GB free
- **Internet connection**: Only needed for downloading prerequisites (Node.js, Rust, Ollama, etc.) – the final app runs completely offline.

---

## 🔒 Security Notes

- **Ollama** is configured to listen only on `127.0.0.1:11434` (loopback), so it is **not exposed** to the network.  
- The scripts **do not modify** Windows Firewall rules.  
- All tools are installed locally inside `C:\ViberizeDesktop` – no system‑wide changes except for Visual Studio Build Tools (which are required for Rust compilation).

---

## 📄 License

This project is licensed under the MIT License – see the [LICENSE](LICENSE) file for details.

---

## 👤 Author

**Orven F.**  
GitHub: [@orvenf](https://github.com/orvenf)
```

---

## ✅ How to Add the README on GitHub

1. Go to your repository page: `https://github.com/orvenf/Viberize-Desktop`
2. Click the **“Add file”** dropdown button (green button near the top right).
3. Choose **“Create new file”**.
4. In the **“Name your file…”** field, type `README.md`.
5. Paste the entire content above into the large text box.
6. Scroll down and click the green **“Commit new file”** button.

That’s it! Your repository now has a beautiful README. You can repeat the same steps to add a `LICENSE` file if you wish (GitHub even provides a template when you name the file `LICENSE`).

If you need any adjustments (like changing the author name or license), just edit the text before committing.

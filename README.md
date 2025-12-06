<div align="center">

# ⚡ zignal

**A lightweight, fast terminal chat application written in Zig**

[![Zig](https://img.shields.io/badge/Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-AGPL_v3-blue?style=for-the-badge)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-Blize-181717?style=for-the-badge&logo=github)](https://github.com/Blize/zignal)

*For those moments when you need quick, hassle-free communication*

![zignal demo](./public/example.png)

</div>

---

## ✨ Features

- 🍎 **macOS & Linux** — Full support for Unix-like systems
- 💬 **Modern TUI** — Beautiful terminal interface powered by [libvaxis](https://github.com/rockorager/libvaxis)
- 🔌 **Simple Networking** — Connect to anyone instantly
- ⌨️ **Intuitive Controls** — Easy scrolling, filtering, and navigation
- 🪶 **Lightweight** — Single binary, minimal footprint

---

## 📦 Installation

### Prerequisites

- [Zig](https://ziglang.org/download/) **0.15.2**
- macOS or Linux (Windows not supported)

### Dependencies

- [libvaxis](https://github.com/rockorager/libvaxis) — Modern TUI library *(fetched automatically)*

### Build from Source

```bash
# Clone the repository
git clone https://github.com/Blize/zignal.git

# Build the application
cd zignal && zig build

# The binary is ready at zig-out/bin/zignal
```

---

## 🚀 Usage

### Starting a Server

Host a chat room for others to join:

```bash
./zignal server
```

Share your IP address and port with others on your network so they can connect!

### Joining as a Client

```bash
./zignal client <IP> <PORT>

# With a custom username
./zignal client -u YourName <IP> <PORT>
```

### Examples

```bash
# Start a server
./zignal server

# Connect to localhost
./zignal client 127.0.0.1 8080

# Connect with a username
./zignal client -u Alice 192.168.1.100 8080
./zignal client --username Bob 192.168.1.100 8080
```

### Help

```bash
./zignal -h
```

---

## 🎮 Controls & Commands

### Client Commands

| Command   | Description                |
|-----------|----------------------------|
| `/exit`   | Exit the application       |
| `/clear`  | Clear the message history  |
| `/help`   | Show available commands    |

### Server Features

- 📊 Connected users display
- 🔍 Log filtering via input bar
- 📜 Scrollable log history

---

## 🛣️ Roadmap

- [ ] 🔐 End-to-end encryption
- [ ] 💬 Multiple chat rooms
- [ ] 📨 Direct messaging (DMs)
- [ ] 🎨 Customizable themes
- [ ] 📁 File sharing

---

## 🤝 Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

---

## 📄 License

This project is licensed under the **GNU Affero General Public License v3.0** — see the [LICENSE](LICENSE) file for details.


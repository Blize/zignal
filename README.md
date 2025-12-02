# zignal

An easy simple terminal chatting app, for the rare occasions you are on some device where  
you don't wanna install anything properly and you wanna talk with people on your local network

## Installation

1. Clone the repo:

```bash
git clone https://github.com/Blize/zignal.git
```

2. Build the Application:

```bash
cd zignal
```

```bash
zig build
```

```bash
cd zig-out/bin
```

3. Go to [Usage](##Usage)

## Usage

Inside `zig-out/bin` or wherever the binary is, you have the following options:

### Server

Write following command:

```bash
./zignal server
```

Now people in your netowrk should be able to join on your IP and PORT.  
For joining go to the following step.

### Client

> [!NOTE]
> Sometimes your PC doesnt allow Network connections from unknown binary's  
> Either try to give the correct rights to the binary or disable your firewall

To join as a Client you can either use localhost (if the Server is on the same device) or join with IP and PORT.
Command:

```bash
./zignal client [IP] [PORT]
```

### Help

For help write:

```bash
./zignal -h
```

Output:

```bash
Usage: ./zignal <server|client> [OPTIONS] <IP> <PORT>

Options:
  server                              Start the server.
  client [OPTIONS] <IP> <PORT>        Start the client and connect to the specified IP and PORT.

Client Options:
  -u, --username <name>   Set username for chat messages (max 23 characters)

Examples:
  ./zignal server
  ./zignal client 127.0.0.1 8080
  ./zignal client -u Alice 127.0.0.1 8080
  ./zignal client 127.0.0.1 8080 -u Bob
  ./zignal client --username Charlie 127.0.0.1 8080
```

### Example

![example_image](./public/example.png)

### TUI Features

The client now includes a modern TUI (Terminal User Interface) built with [libvaxis](https://github.com/rockorager/libvaxis):

- **Title Bar**: Displays "Zignal Chat" centered at the top
- **Chat Area**: Scrollable message history with color-coded messages:
  - System messages in yellow
  - Server messages in cyan
  - Usernames in magenta/bold
  - Regular text in white
- **Input Box**: Text input with cursor support at the bottom
- **Status Bar**: Shows current username and keyboard shortcuts

**Keyboard Shortcuts:**
- `Enter`: Send message
- `Ctrl+C`: Exit the application
- `Ctrl+L`: Refresh the screen
- `PgUp/PgDn`: Scroll through message history
- `Backspace`: Delete character before cursor
- Standard text input navigation (arrow keys, Home, End, etc.)

**Commands:**
- `/exit`: Exit the application
- `/clear`: Clear the message history
- `/help`: Show available commands

### Future Work

Additional TUI improvements planned:

1. Client:
   - Add other Chats box (multiple chat rooms)

2. Server:
   - Server Log Box with TUI
   - Nicer colors / Filtering between certain types of logs

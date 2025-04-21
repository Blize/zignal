# Compiler
CC = gcc

# Compiler flags
CFLAGS = -Wall -Wextra -pedantic -std=c11 -pthread

# Source files
SRCS = src/main.c src/client/client.c src/server/server.c

# Object files
OBJS = main.o client.o server.o

# Executable name
TARGET = net

# Default target
all: $(TARGET)

# Rule to build the executable
$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $(TARGET) $(OBJS)

# Rule to compile main.o
main.o: src/main.c src/client/client.h src/server/server.h
	$(CC) $(CFLAGS) -c src/main.c

# Rule to compile client.o
client.o: src/client/client.c src/client/client.h
	$(CC) $(CFLAGS) -c src/client/client.c

# Rule to compile server.o
server.o: src/server/server.c src/server/server.h
	$(CC) $(CFLAGS) -c src/server/server.c

# Clean the build
clean:
	rm -f $(OBJS) $(TARGET)


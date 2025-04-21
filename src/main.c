#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "client/client.h"
#include "server/server.h"


void print_help(const char *prog_name) {
    printf("Usage: %s <server|client> [IP] [PORT]\n", prog_name);
    printf("\nOptions:\n");
    printf("  server         Start the server.\n");
    printf("  client <IP> <PORT>  Start the client and connect to the specified IP and PORT.\n");
    printf("\nExamples:\n");
    printf("  %s server\n", prog_name);
    printf("  %s client 127.0.0.1 8080\n", prog_name);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_help(argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        print_help(argv[0]);
        return 0;
    }

    if (strcmp(argv[1], "server") == 0) {
        start_server();
    } 
    else if (strcmp(argv[1], "client") == 0) {
        if (argc != 4) {  // Ensure exactly 3 arguments for client
            print_help(argv[0]);
            return 1;
        }
        const char *server_ip = argv[2];
        int server_port = atoi(argv[3]);
        start_client(server_ip, server_port);
    } 
    else {
        printf("Invalid option. Use 'server' or 'client'.\n");
        print_help(argv[0]);
        return 1;
    }

    return 0;
}



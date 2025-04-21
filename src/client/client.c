#include "client.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <time.h>

#define BUFFER_SIZE 1024


void *receive_messages(void *sock_desc) {
    int sock = *(int *)sock_desc;
    char buffer[BUFFER_SIZE] = {0};
    
    while (1) {
        memset(buffer, 0, BUFFER_SIZE);
        int valread = read(sock, buffer, BUFFER_SIZE);
        if (valread > 0) {
            printf("\n%s\n", buffer); 
        }
    }
}


void start_client(const char *ip, int port) {
    int sock;
    struct sockaddr_in server_addr;
    char buffer[BUFFER_SIZE] = {0};

    client_info_t client_info;  // Declare struct to hold client data

    srand(time(NULL));
    client_info.client_id = rand();  // Random client ID
    printf("[Client]: Generated client ID: %d\n", client_info.client_id);

    // Create socket
    if ((sock = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        perror("[Info]: Socket creation error");
        exit(EXIT_FAILURE);
    }

    client_info.sock = sock; 

    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);

    // Convert IP address
    if (inet_pton(AF_INET, ip, &server_addr.sin_addr) <= 0) {
        printf("\n[Info]: Invalid address/Address not supported \n");
        return;
    }

    // Connect to the server
    if (connect(sock, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        printf("\n[Info]: Connection Failed \n");
        return;
    }

    printf("[Info]: Connected to the server with IP: %s\n", ip);

    // Thread for receiving messages from the server
    pthread_t receive_thread;
    pthread_create(&receive_thread, NULL, receive_messages, (void *)&sock);
    pthread_detach(receive_thread);

    // Continuously send messages to the server
    while (1) {
        printf("Message: ");
        memset(buffer, 0, BUFFER_SIZE); 
        fgets(buffer, BUFFER_SIZE, stdin); 
        
        // Remove newline character from fgets
        buffer[strcspn(buffer, "\n")] = '\0';  

        if (strcmp(buffer, "exit") == 0) {
            printf("[Info]: Exiting...\n");
            break; 
        }

        send(sock, buffer, strlen(buffer), 0);  // Send message to the server
    }

    close(sock);
}



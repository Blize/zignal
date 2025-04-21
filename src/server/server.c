#include "server.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <time.h>  
#include "../client/client.h" 


#define BUFFER_SIZE 1024
#define MAX_CLIENTS 10  // Maximum number of connected clients

int client_sockets[MAX_CLIENTS] = {0};  // Array to store client sockets
pthread_mutex_t clients_mutex = PTHREAD_MUTEX_INITIALIZER;


// Add a client socket to the global list
void add_client(int new_socket) {
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (client_sockets[i] == 0) {
            client_sockets[i] = new_socket;
            break;
        }
    }
    pthread_mutex_unlock(&clients_mutex);
}

// Remove a client socket from the global list
void remove_client(int socket) {
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (client_sockets[i] == socket) {
            client_sockets[i] = 0;
            break;
        }
    }
    pthread_mutex_unlock(&clients_mutex);
}
                                                            

// Broadcast a message to all clients except the sender
void broadcast_message(int sender_socket, const char *message) {
    pthread_mutex_lock(&clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (client_sockets[i] != 0 && client_sockets[i] != sender_socket) {
            send(client_sockets[i], message, strlen(message), 0);
        }
    }
    pthread_mutex_unlock(&clients_mutex);
}

void *handle_client(void *socket_desc) {
    int new_socket = *(int *)socket_desc;

    // Create a client_info_t struct for this client
    client_info_t *client_info = malloc(sizeof(client_info_t));
    if (client_info == NULL) {
        perror("[Server]: Memory allocation failed");
        close(new_socket);
        free(socket_desc);
        pthread_exit(NULL);
    }

    client_info->sock = new_socket; 

    // Generate a random client ID
    srand(time(NULL)); 
    client_info->client_id = rand(); 

    // Get client details (IP address and port)
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
    getpeername(new_socket, (struct sockaddr *)&client_addr, &addr_len);
    
    char client_ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &(client_addr.sin_addr), client_ip, INET_ADDRSTRLEN);
    int client_port = ntohs(client_addr.sin_port);
    
    printf("[Server]: Client %s:%d connected with ID: %d\n", client_ip, client_port, client_info->client_id);
    
    // Add the client to the list of connected clients
    add_client(new_socket);

    char buffer[BUFFER_SIZE] = {0};

    // Main loop to handle incoming messages from the client
    while (1) {
        memset(buffer, 0, BUFFER_SIZE);
        int valread = read(new_socket, buffer, BUFFER_SIZE);
        if (valread <= 0) {
            printf("[Server]: Client %s:%d (ID: %d) disconnected\n", client_ip, client_port, client_info->client_id);
            break;
        }

        // Prepend the client's ID to the message
        char message_with_id[BUFFER_SIZE + 50];
        snprintf(message_with_id, sizeof(message_with_id), "[Client %d]: %s", client_info->client_id, buffer);
        
        printf("[Server]: Client %d sent: %s\n", client_info->client_id, buffer);
        broadcast_message(new_socket, message_with_id);
    }

    // Remove the client from the list when they disconnect
    remove_client(new_socket);

    close(new_socket);
    free(client_info);  // Free the client_info memory
    free(socket_desc);
    pthread_exit(NULL);
}




void start_server(void) {
    int server_fd;
    struct sockaddr_in address;
    socklen_t addrlen = sizeof(address);

    // Create socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("[Server]: Socket failed");
        exit(EXIT_FAILURE);
    }

    // Set up address
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = 0;  // Use any available port

    // Bind the socket to the address
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("[Server]: Bind failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    // Get the dynamically assigned port
    if (getsockname(server_fd, (struct sockaddr *)&address, &addrlen) == -1) {
        perror("[Server]: getsockname failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    printf("[Server]: listening on port %d\n", ntohs(address.sin_port));

    // Listen for connections
    if (listen(server_fd, 3) < 0) {
        perror("Listen failed");
        close(server_fd);
        exit(EXIT_FAILURE);
    }

    while (1) {
        int *new_socket = malloc(sizeof(int)); 
        if ((*new_socket = accept(server_fd, (struct sockaddr *)&address, &addrlen)) < 0) {
            perror("Accept failed");
            free(new_socket);
            continue;          
        }

        // Create a thread to handle the client
        pthread_t client_thread;
        // Really weird stuff here
        if (pthread_create(&client_thread, NULL, handle_client, (void *)new_socket) < 0) {
            perror("Could not create thread");
            free(new_socket);  
            continue;
        }

        // Detach the thread so that resources are automatically released when done
        pthread_detach(client_thread);
    }

    close(server_fd);
}


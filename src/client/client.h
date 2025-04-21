#ifndef CLIENT_H
#define CLIENT_H


typedef struct {
    int sock;
    int client_id;
} client_info_t;

void start_client(const char *ip, int port);

#endif

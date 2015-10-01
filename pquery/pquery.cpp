/* ======================================================
# Created by Alexey Bychko, Percona LLC
# Expanded by Roel Van de Paar, Percona LLC
========================================================= */

#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <cerrno>
#include <vector>
#include <thread>                                 /* c++11 or gnu++11 */
#include <string>
#include <fstream>
#include <sstream>

#include <unistd.h>
#include <getopt.h>

#include <my_global.h>
#include <mysql.h>

using namespace std;

static int verbose_flag;
static int log_all_queries;
static int log_failed_queries;
static int no_shuffle;

char db[] = "test";
char sock[] = "/var/run/mysqld/mysqld.sock";
char sqlfile[] = "pquery.sql";
char outdir[] = "/tmp";

struct conndata{
  char database[255];
  char addr[255];
  char socket[255];
  char username[255];
  char password[255];
  char infile[255];
  char logdir[255];
  int port;
  int threads;
  int queries_per_thread;
} m_conndata;

void executor(int number, const vector<string>& qlist){
  if(verbose_flag){
    printf("Thread %d started\n", number);
  }

  int failed_queries = 0;
  int total_queries = 0;
  int max_con_failures = 250; /* Maximum consecutive failures (likely indicating crash/assert, user priveleges drop etc.) */
  int max_con_fail_count = 0;

  FILE * thread_log = NULL;

  if ((log_failed_queries) || (log_all_queries)){
    ostringstream os;
    os << m_conndata.logdir << "/pquery_thread-" << number << ".sql";
    thread_log = fopen(os.str().c_str(), "w+");
  }

  MYSQL * conn;

  conn = mysql_init(NULL);
  if (conn == NULL){
    printf("Error %u: %s\n", mysql_errno(conn), mysql_error(conn));

    if (thread_log != NULL){
      fclose(thread_log);
    }
    printf("Thread #%d is exiting\n", number);
    return;
  }
  if (mysql_real_connect(conn, m_conndata.addr, m_conndata.username,
  m_conndata.password, m_conndata.database, m_conndata.port, m_conndata.socket, 0) == NULL){
    printf("Error %u: %s\n", mysql_errno(conn), mysql_error(conn));
    mysql_close(conn);
    if (thread_log != NULL){
      fclose(thread_log);
    }
    mysql_thread_end();
    return;
  }

  for (int i=0; i<m_conndata.queries_per_thread; i++){
    int query_number;
    if(no_shuffle){
      query_number = i;
    }else{
    struct timeval t1;
    gettimeofday(&t1, NULL);
    unsigned int seed = t1.tv_usec * t1.tv_sec;
    srand(seed);
    query_number = rand() % qlist.size();
    }
    if (log_all_queries){
      fprintf(thread_log, "%s\n", qlist[query_number].c_str());
    }

    if (mysql_real_query(conn, qlist[query_number].c_str(), (unsigned long)strlen(qlist[query_number].c_str()))){
      failed_queries++;
      if(verbose_flag){
        fprintf(stderr, "# Query: \"%s\" FAILED: %s\n", qlist[query_number].c_str(), mysql_error(conn));
      }
      if (log_failed_queries){
        fprintf(thread_log, "# Query: \"%s\" FAILED: %s\n", qlist[query_number].c_str(), mysql_error(conn));
      }
      max_con_fail_count++;
      if (max_con_fail_count >= max_con_failures){
        printf("* Last %d consecutive queries all failed. Likely crash/assert, user privileges drop, or similar. Ending run.\n", max_con_fail_count);
        if (thread_log != NULL){
          fprintf(thread_log,"# Last %d consecutive queries all failed. Likely crash/assert, user privileges drop, or similar. Ending run.\n", max_con_fail_count);
        }
        break;
      }
    }else{
      if(verbose_flag){
        fprintf(stderr, "%s\n", qlist[query_number].c_str());
      }
      max_con_fail_count=0;
    }
    total_queries++;
    MYSQL_RES * result = mysql_store_result(conn);
    if (result != NULL){
      mysql_free_result(result);
    }
  }

  printf("* SUMMARY: %d/%d queries failed (%.2f%% were successful)\n", failed_queries, total_queries, (total_queries-failed_queries)*100.0/total_queries);
  if (thread_log != NULL){
    fprintf(thread_log,"# SUMMARY: %d/%d queries failed (%.2f%% were successful)\n", failed_queries, total_queries, (total_queries-failed_queries)*100.0/total_queries);
    fclose(thread_log);
  }
  mysql_close(conn);
  mysql_thread_end();
}

int main(int argc, char* argv[]){

  m_conndata.threads = 10;
  m_conndata.port = 0;
  m_conndata.queries_per_thread = 10000;

  char db[] = "test";
  int c;

  strncpy(m_conndata.database, db, strlen(db) + 1);
  strncpy(m_conndata.socket, sock, strlen(sock) + 1);
  strncpy(m_conndata.infile, sqlfile, strlen(sqlfile) + 1);
  strncpy(m_conndata.logdir, outdir, strlen(outdir) + 1);

  while(true){

    static struct option long_options[] = {
      {"database", required_argument, 0, 'd'},
      {"address", required_argument, 0, 'a'},
      {"infile", required_argument, 0, 'i'},
      {"logdir", optional_argument, 0, 'l'},
      {"socket", required_argument, 0, 's'},
      {"port", required_argument, 0, 'p'},
      {"user", required_argument, 0, 'u'},
      {"password", required_argument, 0, 'P'},
      {"threads", required_argument, 0, 't'},
      {"queries_per_thread", required_argument, 0, 'q'},
      {"verbose", no_argument, &verbose_flag, 1},
      {"log_all_queries", no_argument, &log_all_queries, 1},
      {"log_failed_queries", no_argument, &log_failed_queries, 1},
      {"no-shuffle", no_argument, &no_shuffle, 1},
      {0, 0, 0, 0}
    };

    int option_index = 0;

    c = getopt_long_only(argc, argv, "d:a:i:l:s:p:u:P:t:q", long_options, &option_index);

    if (c == -1){
      break;
    }

    switch (c){
      case 'd':
        printf("Database is %s\n", optarg);
        memcpy(m_conndata.database, optarg, strlen(optarg) + 1);
        break;
      case 'a':
        printf("Address is %s\n", optarg);
        memcpy(m_conndata.addr, optarg, strlen(optarg) + 1);
        break;
      case 'i':
        printf("Infile is %s\n", optarg);
        memcpy(m_conndata.infile, optarg, strlen(optarg) + 1);
        break;
      case 'l':
        printf("Logdir is %s\n", optarg);
        memcpy(m_conndata.logdir, optarg, strlen(optarg) + 1);
        break;
      case 's':
        printf("Socket is %s\n", optarg);
        memcpy(m_conndata.socket, optarg, strlen(optarg) + 1);
        break;
      case 'p':
        printf("Port is %s\n", optarg);
        m_conndata.port = atoi(optarg);
        break;
      case 'u':
        printf("User is %s\n", optarg);
        memcpy(m_conndata.username, optarg, strlen(optarg) + 1);
        break;
      case 'P':
        printf("Password is %s\n", optarg);
        memcpy(m_conndata.password, optarg, strlen(optarg) + 1);
        break;
      case 't':
        printf("Starting with %s threads\n", optarg);
        m_conndata.threads = atoi(optarg);
        break;
      case 'q':
        printf("Query limit per thread is %s\n", optarg);
        m_conndata.queries_per_thread = atoi(optarg);
        break;
      default:
        break;
    }
  }                                             //while

  MYSQL * conn;
  conn = mysql_init(NULL);
  if (conn == NULL){
    printf("Error %u: %s\n", mysql_errno(conn), mysql_error(conn));
    printf("* PQUERY: Unable to continue [1], exiting\n");
    mysql_close(conn);
    mysql_library_end();
    exit(EXIT_FAILURE);
  }

  if (mysql_real_connect(conn, m_conndata.addr, m_conndata.username,
  m_conndata.password, m_conndata.database, m_conndata.port, m_conndata.socket, 0) == NULL){
    printf("Error %u: %s\n", mysql_errno(conn), mysql_error(conn));
    printf("* PQUERY: Unable to continue [2], exiting\n");
    mysql_close(conn);
    mysql_library_end();
    exit(EXIT_FAILURE);
  }
  printf("MySQL Connection Info: %s \n", mysql_get_host_info(conn));
  printf("MySQL Client Info: %s \n", mysql_get_client_info());
  printf("MySQL Server Info: %s \n", mysql_get_server_info(conn));

  mysql_close(conn);

  ifstream infile;
  infile.open(m_conndata.infile);

  if (!infile){
    printf("Unable to open SQL file %s: %s\n", m_conndata.infile, strerror(errno));
    exit(EXIT_FAILURE);
  }

  shared_ptr<vector<string>> querylist(new vector<string>);
  string line;

  while (getline(infile, line)){
    if(!line.empty()){
      querylist->push_back(line);
    }
  }
  infile.close();

  /* log replaying */
  if(no_shuffle){
    m_conndata.threads = 1;
    m_conndata.queries_per_thread = querylist->size();
  }
  /* END log replaying */
  vector<thread> threads;
  threads.clear();
  threads.resize(m_conndata.threads);

  for (int i=0; i<m_conndata.threads; i++){
    threads[i] = thread(executor, i, *querylist);
  }

  for (int i=0; i<m_conndata.threads; i++){
    threads[i].join();
  }

  mysql_library_end();

  return EXIT_SUCCESS;
}

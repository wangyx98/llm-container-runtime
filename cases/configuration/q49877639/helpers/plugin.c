#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
static void comm1(char *b, size_t n){ FILE*f=fopen("/proc/1/comm","r"); b[0]=0; if(f){ if(fgets(b,n,f)) b[strcspn(b,"\n")]=0; fclose(f);} }
int main(int argc,char**argv){
  signal(SIGPIPE,SIG_IGN);
  const char*path = argc>1?argv[1]:"/run/docker/plugins/sysd.sock";
  unlink(path);
  int s=socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un a; memset(&a,0,sizeof a); a.sun_family=AF_UNIX; strncpy(a.sun_path,path,sizeof a.sun_path-1);
  if(bind(s,(struct sockaddr*)&a,sizeof a)<0){perror("bind");return 1;} listen(s,16);
  for(;;){ int c=accept(s,0,0); if(c<0)continue; char req[4096]; ssize_t n=read(c,req,sizeof req-1); if(n<=0){close(c);continue;} req[n]=0;
    char body[1024]; char p1[64]; comm1(p1,sizeof p1); const char*iv=getenv("INVOCATION_ID");
    if(strstr(req,"/Plugin.Activate")) snprintf(body,sizeof body,"{\"Implements\":[\"VolumeDriver\"]}");
    else if(strstr(req,"/VolumeDriver.Capabilities")) snprintf(body,sizeof body,"{\"Capabilities\":{\"Scope\":\"local\"}}");
    else if(strstr(req,"/VolumeDriver.List")) snprintf(body,sizeof body,"{\"Volumes\":[]}");
    else if(strstr(req,"/VolumeDriver.Get")) snprintf(body,sizeof body,"{\"Volume\":{\"Name\":\"v\",\"Mountpoint\":\"\",\"Status\":{\"pid\":\"%d\",\"pid1\":\"%s\",\"invocation_id\":\"%s\"}}}",(int)getpid(),p1,iv?iv:"");
    else snprintf(body,sizeof body,"{}");
    char hdr[256]; int hl=snprintf(hdr,sizeof hdr,"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.plugins.v1.1+json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",strlen(body));
    if(write(c,hdr,hl)<0||write(c,body,strlen(body))<0){} close(c);} }

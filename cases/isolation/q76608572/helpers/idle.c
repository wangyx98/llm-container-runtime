/* the workload of every container of the lab: a static program that waits for ever */
#include <unistd.h>

int main(void)
{
    for (;;)
        pause();
}

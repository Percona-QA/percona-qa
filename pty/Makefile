CFLAGS	= -Wall -pedantic

NAME    = pty test_good test_bad test_args
SOURCES = $(wildcard *.c)
ALL_OBJS= $(SOURCES:%.c=%.o)
OBJS    = $(filter-out $(NAME:%=%.o), $(SOURCES:%.c=%.o))

.PHONY:	all, new, clean

all:	$(NAME)

new:	clean all

clean:
	rm -f $(NAME) *.o

$(NAME):	$(ALL_OBJS)
	$(CC) -o $@ $(OBJS) $@.o $(LDFLAGS)

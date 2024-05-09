FROM ubuntu:latest

WORKDIR /odin

ENV PATH "$PATH:/odin:/usr/lib/llvm-17/bin"

# RUN apt-get update && apt-get install -y git bash wget make lsb-release software-properties-common gnupg libmysqlclient-dev
RUN apt-get update && apt-get install -y git bash wget make clang-17 llvm-17 libpq-dev

RUN git clone --depth=1 https://github.com/odin-lang/Odin . && make

RUN git clone --depth=1 https://github.com/laytan/odin-postgresql shared/pq

RUN git clone --depth=1 https://github.com/laytan/temple shared/temple

RUN git clone --depth=1 https://github.com/laytan/back shared/back

RUN git clone http://github.com/laytan/odin-http shared/http && git -C shared/http checkout d5c2a82

WORKDIR /app

COPY ./src .

RUN odin run /odin/shared/temple/cli -- . /odin/shared/temple

RUN odin build . -o:aggressive -microarch:native -no-bounds-check -no-type-assert -out:server
# RUN odin build . -o:size -microarch:native -no-bounds-check -out:server
# RUN odin build . -out:server -o:speed -disable-assert

EXPOSE 8080

ENV ASAN_OPTIONS detect_leaks=0

CMD ["/app/server"]

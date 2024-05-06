package main

// import "core:bytes"
import "base:runtime"
import "core:fmt"
import "core:os"
// import "core:io"
import "core:log"
// import "core:slice"
import "core:strconv"
import "core:math/rand"
import "core:container/queue"
import "core:mem/virtual"

import "shared:back"
import "shared:http"
import nbio "shared:http/nbio/poly"
// import "shared:temple"
import "shared:pq"

HELLO      :: "Hello, World!"
HELLO_JSON :: struct{ message: string }{ HELLO }

logger: log.Logger

main :: proc() {
	back.register_segfault_handler()
	context.assertion_failure_proc = back.assertion_failure_proc

	logger = log.create_console_logger(.Warning)
	context.logger = logger

	opts := http.Default_Server_Opts
	// opts.thread_count = 1

	r: http.Router
	http.router_init(&r)
	defer http.router_destroy(&r)

	http.route_get(&r, "/plaintext", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.headers_set_unsafe(&res.headers, "server", "Odin HTTP")
		http.respond_plain(res, HELLO)
	}))

	http.route_get(&r, "/json", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.headers_set_unsafe(&res.headers, "server", "Odin HTTP")
		http.respond_json(res, HELLO_JSON)
	}))

	http.route_get(&r, "/db", http.handler(db))

	// http.route_get(&r, "/queries", http.handler(queries))
	//
	// http.route_get(&r, "/fortunes", http.handler(fortunes))

	fmt.println("Listening on port 8080")

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	err := http.listen_and_serve(&s, http.router_handler(&r), opts=opts)
	fmt.assertf(err == nil, "Server error: %v", err)
}

Pipeline :: struct {
	conn:       pq.Conn,
	work:       queue.Queue(Work),
	dispatched: queue.Queue(Work),

	writable, readable: bool,
}

Work :: struct {
	res:     ^http.Response,
	do_work: proc() -> bool,
}

@(thread_local)
line: Pipeline

World :: struct {
	id:           i32,
	randomNumber: i32,
}

db :: proc(req: ^http.Request, res: ^http.Response) {
	if line.conn == nil {
		// "tfb-database"
		// "127.0.0.1"
		line.conn = pq.setdb_login("tfb-database", dbname="hello_world", login="benchmarkdbuser", pwd="benchmarkdbpass")
		if pq.status(line.conn) != .Ok do log.panic(pq.error_message(line.conn))

		assert(pq.prepare(line.conn, "world", "SELECT id, randomNumber FROM World WHERE id = $1", 1, nil) != nil)

		assert(pq.set_nonblocking(line.conn, true) == .Success)
		assert(pq.enter_pipeline_mode(line.conn) == true)

		line.writable = true
		line.readable = true

		tick :: proc(_: rawptr) {
			// TODO: unfuck this
			context = runtime.default_context()
			context.logger = logger

			nbio.next_tick(&http.td.io, rawptr(nil), tick)

			if line.readable && queue.len(line.dispatched) > 0 {
				log.debug("readable")
				assert(pq.consume_input(line.conn) == true)

				responses: int
				for !pq.is_busy(line.conn) && queue.len(line.dispatched) > 0 {
					pqres := pq.get_result(line.conn)
					if pqres == nil do continue
					defer pq.clear(pqres)

					#partial switch status := pq.result_status(pqres); status {
					case: log.panicf("unexpected result status %v: %v: %v", status, pq.error_message(line.conn), pq.result_error_message(pqres))
					case .Pipeline_Sync: break
					case .Tuples_OK:
						work := queue.pop_front(&line.dispatched)
						context.temp_allocator = virtual.arena_allocator(&work.res._conn.temp_allocator)

						w: World

						wid := pq.get_value(pqres, 0, 0)
						uwid, idok := strconv.parse_u64_of_base(string(wid[:pq.get_length(pqres, 0, 0)]), 10)
						if wid == nil || !idok do log.panicf("parse id from result error: %s from result %q", pq.error_message(line.conn), wid)
						w.id = i32(uwid)

						wnum := pq.get_value(pqres, 0, 1)
						uwnum, numok := strconv.parse_u64_of_base(string(wnum[:pq.get_length(pqres, 0, 1)]), 10)
						if wnum == nil || !numok do log.panicf("parse number from result error: %s from result: %q", pq.error_message(line.conn), wnum)
						w.randomNumber = i32(uwnum)

						log.debugf("[%i] sending response", work.res._conn.socket)
						responses += 1

						http.headers_set_unsafe(&work.res.headers, "server", "Odin HTTP")
						assert(http.respond_json(work.res, w) == nil)
					}
				}

				if responses > 0 {
					log.infof("responded to %i requests in one tick, got %i waiting on db", responses, queue.len(line.dispatched))
				}

				if pq.is_busy(line.conn) {
					log.debug("server busy, no longer readable")
					line.readable = false
					nbio.poll(&http.td.io, os.Handle(pq.socket(line.conn)), .Read, false, rawptr(nil), proc(_: rawptr, ev: nbio.Poll_Event) {
						log.debug("socket readable")
						line.readable = true
					})
				}
			}
			
			n := queue.len(line.work)
			if line.writable && queue.len(line.work) > 0 {
				log.debug("writable")
				assert(pq.flush(line.conn) != .Failure)

				for queue.len(line.work) > 0 {
					w := queue.peek_front(&line.work)
					assert(w != nil)
					if w.do_work() {
						log.debugf("[%i] worked on request", w.res._conn.socket)
						queue.pop_front(&line.work)
						queue.push_back(&line.dispatched, w^)
					} else {
						log.debugf("[%i] work returned false, no longer writable", w.res._conn.socket)
						line.writable = false
						nbio.poll(&http.td.io, os.Handle(pq.socket(line.conn)), .Write, false, rawptr(nil), proc(_: rawptr, ev: nbio.Poll_Event) {
							log.debug("socket writable")
							line.writable = true
						})
						break
					}
				}

				log.infof("sync point for %i requests", n)
				assert(pq.pipeline_sync(line.conn) == true)
			}
		}
		nbio.next_tick(&http.td.io, rawptr(nil), tick)
	}

	log.debugf("[%i] queueing work", res._conn.socket)
	queue.push_back(&line.work, Work{
		res = res,
		do_work = proc() -> bool {
			id := rand.int31_max(10_000-1) + 1
			id_buf: [6]byte
			strconv.append_uint(id_buf[:], u64(id), 10)

			params: [1][^]byte
			params[0] = &id_buf[0]

			return bool(pq.send_query_prepared(line.conn, "world", 1, &params[0], nil, nil, .Text))
		},
	})
}

// queries :: proc(req: ^http.Request, res: ^http.Response) {
// 	http.headers_set_unsafe(&res.headers, "server", "Odin HTTP")
//
// 	n, nok := strconv.parse_uint(http.query_get(req.url, "queries"), base=11)
// 	if !nok || n == 0 do n = 1
// 	if n > 500        do n = 500
// 	
// 	Ctx :: struct{
// 		res:  ^http.Response,
// 		rows: []World,
// 		done: int,
// 		ok:   bool,
// 	}
// 	ctx := new(Ctx, context.temp_allocator)
// 	ctx.res  = res
// 	ctx.rows = make([]World, n, context.temp_allocator)
// 	
// 	for _, i in ctx.rows {
// 		context.user_index = i
// 		world_get_rand(ctx, proc(ctx: rawptr, w: World, ok: bool) {
// 			ctx := (^Ctx)(ctx)
// 			ctx.done += 1
// 			
// 			if !ok do ctx.ok = false
//
// 			ctx.rows[context.user_index] = w
//
// 			if ctx.done == len(ctx.rows) {
// 				if !ok {
// 					http.response_status(ctx.res, .Internal_Server_Error)
// 					http.respond(ctx.res)
// 					return
// 				}
//
// 				assert(http.respond_json(ctx.res, ctx.rows) == nil)
// 			}
// 		})
// 	}
// }
//
// fortunes_tmpl := temple.compiled("fortunes.temple.html", []Fortune)
//
// fortunes :: proc(req: ^http.Request, res: ^http.Response) {
// 	rows, ok := fortunes_all()
// 	if !ok {
// 		http.response_status(res, .Internal_Server_Error)
// 		http.respond(res)
// 		return
// 	}
// 	
// 	append(&rows, Fortune{
// 		message = "Additional fortune added at request time.",
// 	})
//
// 	slice.sort_by(rows[:], proc(a, b: Fortune) -> bool { return a.message < b.message })
//
// 	bytes.buffer_grow(&res._buf, fortunes_tmpl.approx_bytes)
//
// 	http.headers_set_unsafe(&res.headers,"server", "Odin HTTP")
// 	http.headers_set_content_type(&res.headers, "text/html; charset=utf-8")
// 	http.response_status(res, .OK)
// 	
// 	buf: [256]byte = ---
// 	rw: http.Response_Writer
// 	w := http.response_writer_init(&rw, res, buf[:])
// 	defer io.close(w)
//
// 	if _, err := fortunes_tmpl.with(w, rows[:]); err != nil {
// 		log.errorf("error writing template: %v", err)
// 	}
// }

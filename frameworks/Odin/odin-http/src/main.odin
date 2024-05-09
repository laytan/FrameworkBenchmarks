package main

// import "core:bytes"
import      "base:runtime"
import intr "base:intrinsics"

import      "core:bytes"
import      "core:container/queue"
import      "core:fmt"
import      "core:io"
import      "core:log"
import      "core:math/rand"
import      "core:mem/virtual"
import      "core:os"
import      "core:slice"
import      "core:strconv"

import      "shared:back"
import      "shared:http"
import      "shared:pq"
import      "shared:temple"
import nbio "shared:http/nbio/poly"

HELLO      :: "Hello, World!"
HELLO_JSON :: struct{ message: string }{ HELLO }

logger: log.Logger

main :: proc() {
	back.register_segfault_handler()
	context.assertion_failure_proc = back.assertion_failure_proc

	logger = log.create_console_logger(.Warning)
	context.logger = logger

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

	http.route_get(&r, "/queries", http.handler(queries))

	http.route_get(&r, "/cached%-queries", http.handler(cached_queries))

	http.route_get(&r, "/fortunes", http.handler(fortunes))

	fmt.println("Listening on port 8080")

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	err := http.listen_and_serve(&s, http.router_handler(&r))
	fmt.assertf(err == nil, "Server error: %v", err)
}

Pipeline :: struct {
	conn:       pq.Conn,
	work:       queue.Queue(Work),
	dispatched: queue.Queue(Work),

	writable, readable: bool,
}

World_Work :: struct {}

Fortunes_Work :: struct {}

Queries_Work :: struct {
	rows: ^[]World,
	done: ^int,
}

World_Update_Work :: struct {}
World_Do_Update_Work :: struct {}

Work :: struct {
	res: ^http.Response,
	data: union {
		World_Work,
		Queries_Work,
		Fortunes_Work,
		World_Update_Work,
		World_Do_Update_Work,
	},
}

@(thread_local)
line: Pipeline

ensure_line :: #force_inline proc() {
	if intr.expect(line.conn != nil, true) {
		return
	}

	// "tfb-database"
	// "127.0.0.1"
	line.conn = pq.setdb_login("127.0.0.1", dbname="hello_world", login="benchmarkdbuser", pwd="benchmarkdbpass")
	if pq.status(line.conn) != .Ok do log.panic(pq.error_message(line.conn))

	assert(pq.prepare(line.conn, "world", "SELECT id, randomNumber FROM World WHERE id = $1", 1, nil) != nil)
	assert(pq.prepare(line.conn, "world_update", "UPDATE World SET randomNumber = $2 WHERE id = $1", 2, nil) != nil)
	assert(pq.prepare(line.conn, "fortunes", "SELECT id, message FROM Fortune", 0, nil) != nil)

	assert(pq.set_nonblocking(line.conn, true) == .Success)
	assert(pq.enter_pipeline_mode(line.conn) == true)

	line.writable = true
	line.readable = true

	sock := pq.socket(line.conn)
	nbio.poll(&http.td.io, os.Handle(sock), .Read, true, 69, proc(_: int, ev: nbio.Poll_Event) {
		line.readable = true
	})

	// nbio.poll(&http.td.io, os.Handle(sock), .Write, true, 69, proc(_: int, ev: nbio.Poll_Event) {
	// 	line.writable = true
	// })

	tick :: proc(_: rawptr) {
		// TODO: unfuck this
		context = runtime.default_context()
		context.logger = logger

		nbio.next_tick(&http.td.io, rawptr(nil), tick)

		if line.readable && queue.len(line.dispatched) > 0 {
			assert(pq.consume_input(line.conn) == true)

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

					switch wd in work.data {
					case World_Work:
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

						http.headers_set_unsafe(&work.res.headers, "server", "Odin HTTP")
						assert(http.respond_json(work.res, w) == nil)
					case Queries_Work:
						w := &wd.rows[wd.done^]
						wd.done^ += 1

						wid := pq.get_value(pqres, 0, 0)
						uwid, idok := strconv.parse_u64_of_base(string(wid[:pq.get_length(pqres, 0, 0)]), 10)
						if wid == nil || !idok do log.panicf("parse id from result error: %s from result %q", pq.error_message(line.conn), wid)
						w.id = i32(uwid)

						wnum := pq.get_value(pqres, 0, 1)
						uwnum, numok := strconv.parse_u64_of_base(string(wnum[:pq.get_length(pqres, 0, 1)]), 10)
						if wnum == nil || !numok do log.panicf("parse number from result error: %s from result: %q", pq.error_message(line.conn), wnum)
						w.randomNumber = i32(uwnum)

						if wd.done^ == len(wd.rows) {
							log.debugf("[%i] sending response", work.res._conn.socket)
							http.headers_set_unsafe(&work.res.headers, "server", "Odin HTTP")
							assert(http.respond_json(work.res, wd.rows^) == nil)
						}
					case World_Update_Work:
						// TODO:
						unimplemented()

					case Fortunes_Work:
						rows := make([dynamic]Fortune, context.temp_allocator)
						
						count := pq.n_tuples(pqres)
						for row in 0..<count {
							id := pq.get_value(pqres, row, 0)
							uid, idok := strconv.parse_u64_of_base(string(id[:pq.get_length(pqres, row, 0)]), 10)
							if id == nil || !idok do log.panicf("parse id from result error: %s from result %q", pq.error_message(line.conn), uid)

							message := pq.get_value(pqres, row, 1)
							append(&rows, Fortune{
								id = uid,
								message = string(message[:pq.get_length(pqres, row, 1)]),
							})
						}

						append(&rows, Fortune{
							message = "Additional fortune added at request time.",
						})

					   	slice.sort_by(rows[:], proc(a, b: Fortune) -> bool { return a.message < b.message })

					   	bytes.buffer_grow(&work.res._buf, fortunes_tmpl.approx_bytes)

					   	http.headers_set_unsafe(&work.res.headers,"server", "Odin HTTP")
					   	http.headers_set_content_type(&work.res.headers, "text/html; charset=utf-8")
					   	http.response_status(work.res, .OK)

					   	buf: [1024]byte = ---
					   	rw: http.Response_Writer
					   	w := http.response_writer_init(&rw, work.res, buf[:])
					   	defer io.close(w)

					   	if _, err := fortunes_tmpl.with(w, rows[:]); err != nil {
							log.errorf("error writing template: %v", err)
					   	}
					case World_Do_Update_Work:
						unreachable()
					}
				}
			}

			if pq.is_busy(line.conn) {
				line.readable = false
			}
		}
		
		if line.writable && queue.len(line.work) > 0 {
			assert(pq.flush(line.conn) == .Success)

			for queue.len(line.work) > 0 {
				w := queue.peek_front(&line.work)
				assert(w != nil)
				
				switch wd in w.data {
				case World_Work, Queries_Work, World_Update_Work:
					id := rand.int31_max(10_000-1) + 1
					id_buf: [6]byte
					strconv.append_uint(id_buf[:], u64(id), 10)

					params: [1][^]byte
					params[0] = &id_buf[0]
					assert(pq.send_query_prepared(line.conn, "world", 1, &params[0], nil, nil, .Text) == true)
				case Fortunes_Work:
					assert(pq.send_query_prepared(line.conn, "fortunes", 0, nil, nil, nil, .Text) == true)
				case World_Do_Update_Work:
					unimplemented()
					// id_buf: [6]byte
					// strconv.append_uint(id_buf[:], u64(wd.id), 10)
					//
					// rand := rand.int31_max(10_000-1) + 1
					// rand_buf: [6]byte
					// strconv.append_uint(rand_buf[:], u64(rand), 10)
					//
					// params: [2][^]byte
					// params[0] = &id_buf[0]
					// params[1] = &rand_buf[0]
					// assert(pq.send_query_prepared(line.conn, "world_update", 2, &params[0], nil, nil, .Text))
				}

				queue.pop_front(&line.work)
				queue.push_back(&line.dispatched, w^)
			}

			assert(pq.pipeline_sync(line.conn) == true)
		}
	}
	nbio.next_tick(&http.td.io, rawptr(nil), tick)
}

World :: struct {
	id:           i32,
	randomNumber: i32,
}

// NOTE: For some reason this is slow on lower connection count (16, 32) and very very fast at higher counts.

db :: proc(req: ^http.Request, res: ^http.Response) {
	ensure_line()

	queue.push_back(&line.work, Work{
		res = res,
		data = World_Work{},
	})
}

queries :: proc(req: ^http.Request, res: ^http.Response) {
	ensure_line()

	n, _, _ := http.query_get_int(req.url, "queries", base=10)
	n = clamp(n, 1, 500)

	rows := new([]World, context.temp_allocator)
	rows^ = make([]World, n, context.temp_allocator)
	done := new(int, context.temp_allocator)

	// NOTE: this is dumb.
	queue.reserve(&line.work, queue.len(line.work)+n)
	for _ in 0..<n {
		queue.push_back(&line.work, Work{
			res = res,
			data = Queries_Work{
				rows = rows,
				done = done,
			},
		})
	}
}


Fortune :: struct {
	id:      u64,
	message: string,
}

fortunes_tmpl := temple.compiled("fortunes.temple.html", []Fortune)

fortunes :: proc(req: ^http.Request, res: ^http.Response) {
	ensure_line()

	queue.push_back(&line.work, Work{
		res = res,
		data = Fortunes_Work{},
	})
}

@(thread_local)
cache: map[i32]i32

cached_queries :: proc(req: ^http.Request, res: ^http.Response) {
	ensure_line()

	if intr.expect(cache == nil, false) {
		cache = make(map[i32]i32, 10_000, context.allocator)

		assert(pq.set_nonblocking(line.conn, false) == .Success)
		assert(pq.exit_pipleline_mode(line.conn) == true)
		defer {
			assert(pq.set_nonblocking(line.conn, true) == .Success)
			assert(pq.enter_pipeline_mode(line.conn) == true)
		}

		pqres := pq.exec(line.conn, "SELECT id, randomNumber FROM CachedWorld")
		if pqres == nil do log.panicf("select all cached worlds failed: %v", pq.error_message(line.conn))
		#partial switch status := pq.result_status(pqres); status {
		case: log.panicf("select all cached worlds failed with status %v: %v", status, pq.error_message(line.conn))
		case .Tuples_OK:
			count := pq.n_tuples(pqres)
			assert(count == 10_000, "mismatched counts")
			for row in 0..<count {
				id := pq.get_value(pqres, row, 0)
				uid, idok := strconv.parse_u64_of_base(string(id[:pq.get_length(pqres, row, 0)]), 10)
				if id == nil || !idok do log.panicf("parse id from result error: %s from result %q", pq.error_message(line.conn), uid)

				random := pq.get_value(pqres, row, 1)
				urandom, randomok := strconv.parse_u64_of_base(string(random[:pq.get_length(pqres, row, 1)]), 10)
				if random == nil || !randomok do log.panicf("parse id from result error: %s from result %q", pq.error_message(line.conn), urandom)

				cache[i32(uid)] = i32(urandom)
			}
		}
	}

	n, _, _ := http.query_get_int(req.url, "queries", base=10)
	n = clamp(n, 1, 500)

	worlds := make([]World, n, context.temp_allocator)
	for &world in worlds {
		id := rand.int31_max(10_000-1) + 1
		world = World{id, cache[id]}
	}

	http.headers_set_unsafe(&res.headers, "server", "Odin HTTP")
	http.respond_json(res, worlds)
}

updates :: proc(req: ^http.Request, res: ^http.Response) {
	ensure_line()
	
	unimplemented()
}

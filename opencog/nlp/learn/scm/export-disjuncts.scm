;
; export-disjuncts.scm
;
; Export disjuncts from the atomspace into a dattabase that can be
; used by the Link-Grammar parser.
;
; Copyright (c) 2015 Rohit Shinde
; Copyright (c) 2017 Linas Vepstas
;
; ---------------------------------------------------------------------
; OVERVIEW
; --------
; After a collection of disjuncts has been observed by the MST pipeline,
; the can be exported to the link Grammar parser, where they can be used
; to parse sentences.
;
; Currently an hack job.
; What's hacky here is that no word-classes (clusters) are used.
; Needs the guile-dbi interfaces, in order to write the SQL files.
;
; Example usage:
; (export-all-csets "dict.db" "EN_us")
;
; Then, in bash:
; cp -pr /usr/local/share/link-grammar/demo-sql ./my-place
; cp dict.db ./my-place
; link-parser ./my-place
; ---------------------------------------------------------------------

(use-modules (srfi srfi-1))
(use-modules (dbi dbi))  ; The guile-dbi interface to SQLite3
(use-modules (opencog))
(use-modules (opencog matrix))
(use-modules (opencog sheaf))

; ---------------------------------------------------------------------
; Return a caching version of AFUNC. Here, AFUNC is a function that
; takes a single atom as an argument, and returns some object
; associated with that atom.
;
; This returns a function that returns the same values that AFUNC would
; return, for the same argument; but if a cached value is available,
; then return just that.  In order for the cache to be valid, the AFUNC
; must be side-effect-free.
;
(define (make-afunc-cache AFUNC)

	; Define the local hash table we will use.
	(define cache (make-hash-table))

	; Guile needs help computing the hash of an atom.
	(define (atom-hash ATOM SZ) (modulo (cog-handle ATOM) SZ))
	(define (atom-assoc ATOM ALIST)
		(find (lambda (pr) (equal? ATOM (car pr))) ALIST))

	(lambda (ITEM)
		(define val (hashx-ref atom-hash atom-assoc cache ITEM))
		(if val val
			(let ((fv (AFUNC ITEM)))
				(hashx-set! atom-hash atom-assoc cache ITEM fv)
				fv)))
)

; ---------------------------------------------------------------------
; Convert an integer into a string of letters. Useful for creating
; link-names.  This prepends the letter "T" to all names, so that
; all MST link-names start with this letter.
; Example:  0 --> TA, 1 --> TB
(define (number->tag num)

	; Convert number to a list of letters.
	(define (number->letters num)
		(define letters "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
		(unfold-right negative?
			(lambda (i) (string-ref letters (remainder i 26)))
			(lambda (i) (- (quotient i 26) 1))
			num))

	(list->string (cons #\T (number->letters num)))
)

;  ---------------------------------------------------------------------
;
; Given a word-pair atom, return a synthetic link name
; The link names are issued in serial order, first-come, first-served.
;
(define get-cnr-name
	(let ((cnt 0))

		; Notice that the lambda does not actually depend on the
		; word-pair. It just issues a new string.  The function
		; cache is what is able to detect and re-emit a previously
		; issued link name.
		(make-afunc-cache
			(lambda (WORD-PAIR)
				(set! cnt (+ cnt 1))
				(number->tag cnt))))
)

;  ---------------------------------------------------------------------

(define cnr-to-left (ConnectorDir "-"))

(define (cset-to-lg-dj SECTION)
"
  cset-to-lg-dj - SECTION should be a SectionLink
  Return a link-grammar compatible disjunct string.
"
	; The germ of the section (the word)
	(define germ (gar SECTION))

	; Get a link-name identifying this word-pair.
	(define (connector-to-lg-link CONNECTOR)
		(define cnr (gar CONNECTOR))
		(define dir (gdr CONNECTOR))

		(if (equal? dir cnr-to-left)
			(get-cnr-name (ListLink cnr germ))
			(get-cnr-name (ListLink germ cnr))
		)
	)

	; Get a connector, by concatenating the link name with the direction.
	(define (connector-to-lg-cnr CONNECTOR)
		(string-append
			(connector-to-lg-link CONNECTOR)
			(cog-name (gdr CONNECTOR))))

	; A list of connnectors, in the proper connector order.
	(define cnrs (map connector-to-lg-cnr (cog-outgoing-set (gdr SECTION))))

	; Create a single string of the connectors, in order.
	(fold
		(lambda (cnr dj) (if dj (string-append dj " & " cnr) cnr))
		#f cnrs)
)

;  ---------------------------------------------------------------------

; Create a function that can store connector-sets to a database.
;
; DB-NAME is the databse name to write to.
; LOCALE is the locale to use; e.g EN_us or ZH_cn
; COST-FN is a function that assigns a link-parser cost to each disjunct.
;
; This returns a function that will write sections to the database.
; That is, this returns (lambda (SECTION) ...) so that, when you call
; it, that section will be saved to the database. Calling with #f closes
; the database.
;
; Example usage:
; (make-database "dict.db" "EN_us" ...)
;
(define (make-database DB-NAME LOCALE COST-FN)
	(let ((db-obj (dbi-open "sqlite3" DB-NAME))
			(cnt 0)
		)

		; Add data to the database
		(define (add-section SECTION)
			; The germ of the section (the word)
			(define germ-str (cog-name (gar SECTION)))
			(define dj-str (cset-to-lg-dj SECTION))

			(format #t "Will insert ~A: ~A;\n" germ-str dj-str)

			; Insert the word
			(set! cnt (+ cnt 1))
			(dbi-query db-obj (format #f
				"INSERT INTO Morphemes VALUES ('~A', '~A.~D', '~A');"
				germ-str germ-str cnt germ-str))

			(if (not (equal? 0 (car (dbi-get_status db-obj))))
				(throw 'fail-insert 'make-database
					(cdr (dbi-get_status db-obj))))

			; Insert the disjunct, assigning a cost according
			; to the float-ppoint value returned by teh function
			(dbi-query db-obj (format #f
				"INSERT INTO Disjuncts VALUES ('~A', '~A', ~F);"
				germ-str dj-str (COST-FN SECTION)))

			(if (not (equal? 0 (car (dbi-get_status db-obj))))
				(throw 'fail-insert 'make-database
					(cdr (dbi-get_status db-obj))))
		)

		; Create the tables for words and disjuncts.
		; Refer to the Link Grammar documentation to see a
		; description of this table format. Specifically,
		; take a look at `dict.sql`.
		(dbi-query db-obj (string-append
			"CREATE TABLE Morphemes ( "
			"morpheme TEXT NOT NULL, "
			"subscript TEXT UNIQUE NOT NULL, "
			"classname TEXT NOT NULL);" ))

		(if (not (equal? 0 (car (dbi-get_status db-obj))))
			(throw 'fail-create 'make-database
				(cdr (dbi-get_status db-obj))))

		(dbi-query db-obj
			"CREATE INDEX morph_idx ON Morphemes(morpheme);")

		(dbi-query db-obj (string-append
			"CREATE TABLE Disjuncts ("
			"classname TEXT NOT NULL, "
			"disjunct TEXT NOT NULL, "
			"cost REAL );"))

		(dbi-query db-obj
			"CREATE INDEX class_idx ON Disjuncts(classname);")

		(dbi-query db-obj (string-append
			"INSERT INTO Morphemes VALUES ("
			"'<dictionary-version-number>', "
			"'<dictionary-version-number>', "
			"'<dictionary-version-number>');"))

		(dbi-query db-obj (string-append
			"INSERT INTO Disjuncts VALUES ("
			"'<dictionary-version-number>', 'V5v4v0+', 0.0);"))

		(dbi-query db-obj (string-append
			"INSERT INTO Morphemes VALUES ("
			"'<dictionary-locale>', "
			"'<dictionary-locale>', "
			"'<dictionary-locale>');"))

		(dbi-query db-obj (string-append
			"INSERT INTO Disjuncts VALUES ("
			"'<dictionary-locale>', '"
			(string-map (lambda (c) (if (equal? c #\_) #\4 c)) LOCALE)
			"+', 0.0);"))

		; Return function that adds data to the database
		; If SECTION if #f, the database is closed.
		(lambda (SECTION)
			(if SECTION
				(add-section SECTION)
				(dbi-close db-obj))
		))
)

;  ---------------------------------------------------------------------

; Write all connector sets to a Link Grammar-compatible sqlite3 file.
; DB-NAME is the databse name to write to.
; LOCALE is the locale to use; e.g EN_us or ZH_cn
;
; Note that link-grammar expects the database file to be called
; "dict.db", always!
;
; Example usage:
; (export-all-csets "dict.db" "EN_us")
(define (export-all-csets DB-NAME LOCALE)
	(define psa (make-pseudo-cset-api))

	; Get from SQL
	; (psa 'fetch-pairs)

	(define all-csets (psa 'all-pairs))

	(define (cost-fn SECTION) 0.0)

	; Create a database
	(define sectioner (make-database DB-NAME LOCALE cost-fn))

	; Dump all the connector sets into the database
	(map sectioner all-csets)

	; Close the database
	(sectioner #f)
)
;  ---------------------------------------------------------------------


build:
	perl parse.pl Magdir/* > out
	perl py.pl
	cat file.py out.py > tar.py


document.pdf : document.md examples/*.dsp
	make -C examples
	pandoc document.md -o document.pdf --from markdown --template=eisvogel --listings

clean:
	rm -f document.pdf
	make -C examples clean




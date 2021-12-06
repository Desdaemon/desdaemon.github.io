sync:
	cd ../markdown_editor && just build-web
	cp -r ../markdown_editor/build/web/* ./

#include "EXTERN.h"
#include "perl.h"

#ifdef DEBUG
#undef DEBUG
#endif

#define DEBUG 1

struct p_state {
  SV* buf;
  int bufpos;

  int strict_comment;

  CV* text_cb;
  CV* start_cb;
  CV* end_cb;
  CV* decl_cb;
  CV* com_cb;
};

int isHALNUM(int c)
{
  return isALNUM(c) || c == '.' || c == '-';
}

void html_text(struct p_state* p_state, char* beg, char *end)
{
  if (beg == end)
    return;
  printf(">> text: [");
  while (beg < end)
    putchar(*beg++);
  putchar(']');
  putchar('\n');
}

void html_end(struct p_state* p_state,
	      char *tag_beg, char *tag_end,
	      char *beg, char *end)
{
  printf(">> end: [");
  while (tag_beg < tag_end) {
    int l = toLOWER(*tag_beg);
    putchar(l);
    tag_beg++;
  }
  printf("] [");
  while (beg < end)
    putchar(*beg++);
  printf("]\n");
}

void html_start(struct p_state* p_state,
		char *tag_beg, char *tag_end,
		AV* tokens,
		char *beg, char *end)
{
  int i, len;
  printf(">> start: [");
  while (tag_beg < tag_end) {
    int l = toLOWER(*tag_beg);
    putchar(l);
    tag_beg++;
  }
  printf("] [");
  while (beg < end)
    putchar(*beg++);
  printf("]\n");
  printf("  tokens:");
  len = av_len(tokens);
  for (i = 0; i <= len; i++) {
    SV** svp = av_fetch(tokens, i, 0);
    STRLEN len;
    char *s = SvPV(*svp, len);
    printf(" [");
    while (len--)
      putchar(*s++);
    putchar(']');
  }
  putchar('\n');
}

void html_process(struct p_state* p_state, char*beg, char *end)
{
  printf(">> process: [");
  while (beg < end)
    putchar(*beg++);
  printf("]\n");
}

void html_comment(struct p_state* p_state, char *beg, char *end)
{
  printf(">> comment: [");
  while (beg < end)
    putchar(*beg++);
  printf("]\n");
}

void html_decl(struct p_state* p_state, AV* tokens, char *beg, char *end)
{
  int i, len;
  printf(">> decl: [");
  while (beg < end)
    putchar(*beg++);
  printf("]\n");
  printf(" tokens:");
  len = av_len(tokens);
  for (i = 0; i <= len; i++) {
    SV** svp = av_fetch(tokens, i, 0);
    STRLEN len;
    char *s = SvPV(*svp, len);
    printf(" [");
    while (len--)
      putchar(*s++);
    putchar(']');
  }
  putchar('\n');
}


char* html_parse_decl(struct p_state* p_state, char *beg, char *end)
{
  char *s = beg;

  assert(end - beg >= 1);

  if (isALPHA(*s)) {
    AV* tokens = newAV();
    s++;
    /* declaration */
    while (s < end && isHALNUM(*s))
      s++;
    /* first word available */
    av_push(tokens, newSVpv(beg, s - beg));

    while (s < end && isSPACE(*s)) {
      s++;
      while (s < end && isSPACE(*s))
	s++;

      if (s == end)
	return beg;

      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  return beg;
	s++;
	av_push(tokens, newSVpv(str_beg, s - str_beg));
      }
      else if (*s == '-') {
	/* comment */
	char *com_beg = s;
	s++;
	if (s == end)
	  return beg;
	if (*s != '-')
	  return 0;
	s++;

	while (1) {
	  while (s < end && *s != '-')
	    s++;
	  if (s == end)
	    return beg;
	  s++;
	  if (s == end)
	    return beg;
	  if (*s == '-') {
	    s++;
	    av_push(tokens, newSVpv(com_beg, s - com_beg));
	    break;
	  }
	}
      }
      else if (*s != '>') {
	/* plain word */
	char *word_beg = s;
	s++;
	while (s < end && !isSPACE(*s) && *s != '>')
	  s++;
	if (s == end)
	  return beg;
	av_push(tokens, newSVpv(word_beg, s - word_beg));
      }
      else {
	break;
      }
    }

    if (s == end)
      return beg;
    if (*s == '>') {
      s++;
      html_decl(p_state, tokens, beg, s-1);
      return s;
    }
    return 0;

  } else if (*s == '-') {
    s++;
    /* comment? */
    if (s == end)
      return beg;

    if (*s == '-') {
      s++;
      /* yes, it is really a comment */
      
# if 0
      if (p_state->strict_comment) {
	/* XXX */
      }
      else
#endif
      {
	char *end_com;
	/* try to locate /--\s*>/ which signals end-of-comment */
      LOCATE_END:
	while (s < end && *s != '-')
	  s++;
	end_com = s - 1;
	if (s < end) {
	  s++;
	  if (s < end && *s == '-') {
	    s++;
	    while (s < end && isSPACE(*s))
	      s++;
	    if (s < end && *s == '>') {
	      s++;
	      /* yup */
	      html_comment(p_state, beg+2, end_com);
	      return s;
	    }
	  }
	  if (s < end) {
	    s = end_com + 2;
	    goto LOCATE_END;
	  }
	}
	
	if (s == end)
	  return beg;
      }
    }
  }
  return 0;
}

char* html_parse_start(struct p_state* p_state, char *beg, char *end)
{
  char *s = beg;
  char *tag_end;
  AV* tokens = 0;

  assert(beg[0] == '<' && isALPHA(beg[1]) && end - beg > 2);
  s += 2;

  while (s < end && isHALNUM(*s))
    s++;
  tag_end = s;
  while (s < end && isSPACE(*s))
    s++;
  if (s == end)
    return beg;

  tokens = newAV();

  while (isALPHA(*s)) {
    /* attribute */
    char *attr_beg = s;
    s++;
    while (s < end && isHALNUM(*s))
      s++;
    av_push(tokens, newSVpv(attr_beg, s - attr_beg));

    while (s < end && isSPACE(*s))
      s++;
    if (s == end)
      return beg;

    if (*s == '=') {
      /* with a value */
      s++;
      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	return beg;
      if (*s == '>') {
	/* parse it similar to ="" */
	av_push(tokens, newSVpvn("", 0));
	break;
      }
      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  return beg;
	s++;
	av_push(tokens, newSVpvn(str_beg+1, s - str_beg - 2));
      }
      else {
	char *word_start = s;
	while (s < end && !isSPACE(*s) && *s != '>')
	  s++;
	if (s == end)
	  return beg;
	av_push(tokens, newSVpv(word_start, s - word_start));
      }

      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	return beg;
    }
    else {
      av_push(tokens, newSVpv("*", 1));
    }
  }

  if (*s == '>') {
    s++;
    /* done */
    html_start(p_state, beg+1, tag_end, tokens, beg, s);
    return s;
  }
  return 0;
}

void html_parse(struct p_state* p_state,
	       SV* chunk)
{
  char *s, *t, *end;
  STRLEN len;

#ifdef DEBUG
  {
    STRLEN len;
    char *s;

    printf("html_parse\n");
    if (p_state->buf) {
      s = SvPV(p_state->buf, len);
      printf("  buf   = [%s]\n", s);
    }
    if (chunk && SvOK(chunk)) {
      s = SvPV(chunk, len);
      printf("  chunk = [%s]\n", s);
    }
  }
#endif

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_text(p_state, s, s+len);
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
    return;
  }


  if (p_state->buf) {
    sv_catsv(p_state->buf, chunk);
    s = SvPV(p_state->buf, len);
  }
  else {
    s = SvPV(chunk, len);
  }

  if (!len)
    return; /* nothing to do */

  t = s;
  end = s + len;

  while (1) {

    /* first we try to match as much text as possible */
    while (s < end && *s != '<')
      s++;
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s);
	t = s;
      }
      else {
	s--;
	if (isSPACE(*s)) {
	  /* wait with white space at end */
	  while (s > t && isSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s > t && !isSPACE(*s))
	    s--;
	  while (s > t && isSPACE(*s))
	    s--;
	}
	s++;
	html_text(p_state, t, s);
	t = s;
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' */
    s++;

    if (isALPHA(*s)) {
      /* start tag */
      char *new_pos = html_parse_start(p_state, s-1, end);
      if (new_pos == s-1)
	break;
      else if (new_pos)
	t = s = new_pos;
    }
    else if (*s == '/') {
      /* end tag */
      s++;
      if (isALPHA(*s)) {
	char *tag_start = s;
	char *tag_end;
	s++;
	while (s < end && isHALNUM(*s))
	  s++;
	tag_end = s;
	while (s < end && isSPACE(*s))
	  s++;
	if (s < end) {
	  if (*s == '>') {
	    s++;
	    /* a complete end tag has been recognized */
	    html_end(p_state, tag_start, tag_end, t, s);
	    t = s;
	  }
	}
	else {
	  s = t;
	  break;  /* need to see more stuff */
	}
      }
    }
    else if (*s == '!') {
      /* declaration or comment */
      char *new_pos;
      s++;
      new_pos = html_parse_decl(p_state, s, end);
      if (new_pos == s) {
	/* no progress, need more */
	s = t;
	break;
      }
      else if (new_pos) {
	t = s = new_pos;
      }
    }
    else if (*s == '?') {
      /* processing instruction */
      s++;
      while (s < end && *s != '>')
	s++;
      if (*s == '>') {
	s++;
	/* a complete processing instruction seen */
	html_process(p_state, t+2, s-1);
	t = s;
      }
      else {
	/* need more */
	s = t;
	break;
      }
    }

    /* if we get out here thene this was not a conforming tag, so
     * treat it is plain text.
     */
  }

  if (s == end) {
    if (p_state->buf) {
      /* XXX it is probably more efficient to always have a buffer variable,
	 and then just mark it as unused by clearing SvOK
       */
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
  }
  else {
    /* need to keep rest in buffer */
    if (p_state->buf) {
      /* chop off some chars at the beginning */
      sv_chop(p_state->buf, s);
    }
    else {
      p_state->buf = newSVpv(s, end - s);
    }
  }
  return;
}



#if 1

int main(int argc, char** argv, char** env)
{
  struct p_state p;
  SV* sv1;
  SV* sv2;
  SV* sv3;
  SV* sv4;

  memset(&p, 0, sizeof(p));
  sv1 = newSVpv("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.0//EN\" \"http://www.w3.org/TR/REC-html40/strict.dtd\">\nbar <a href='foo'>foo</a>   <!--foo", 0);
  sv2 = newSVpv("--><FONT size=+3> -><a href=\"", 0);
  sv3 = newSVpv("'>'\">bar</A><?</fo", 0);
  sv4 = newSVpv("NT>foo &bar", 0);
  

  html_parse(&p, sv1);
  html_parse(&p, sv2);
  html_parse(&p, sv3);
  html_parse(&p, sv4);
  html_parse(&p, 0);
  html_parse(&p, 0);

  return 0;
}

#endif

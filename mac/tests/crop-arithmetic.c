// La stessa aritmetica di publish(): dato quanto e' grande la finestra e quanto
// Windows ha confermato, che rettangolo si mostra?
#include <stdio.h>
static void crop(int w,int h,int aw,int ah,int*ocw,int*och){
    int cw=w, ch=h;
    if (cw>aw) cw=aw;
    if (ch>ah) ch=ah;
    if (w>0&&h>0){
        if ((long long)cw*h > (long long)ch*w) cw=(int)((long long)ch*w/h);
        else                                   ch=(int)((long long)cw*h/w);
    }
    if(cw<1)cw=1; if(ch<1)ch=1;
    *ocw=cw; *och=ch;
}
static int failures = 0;
int main(void){
    struct { int w,h,aw,ah; const char*caso; } t[] = {
        {1209,806,1209,806,"a riposo: crop = finestra"},
        {1400,900,1209,806,"allargo: Windows non ha ancora seguito"},
        {1000,700,1209,806,"stringo: sempre sicuro"},
        {1728,1084,1209,806,"a tutto schermo, Windows indietro"},
        {1209,806,1400,900,"Windows piu' grande della finestra"},
    };
    for (unsigned i=0;i<sizeof t/sizeof*t;i++){
        int cw,ch; crop(t[i].w,t[i].h,t[i].aw,t[i].ah,&cw,&ch);
        double rf=(double)t[i].w/t[i].h, rc=(double)cw/ch;
        printf("%-42s fin %dx%d ack %dx%d -> crop %dx%d  rapporti %.3f/%.3f %s\n",
            t[i].caso,t[i].w,t[i].h,t[i].aw,t[i].ah,cw,ch,rf,rc,
            (rf-rc<0.005&&rc-rf<0.005)?"OK":"BANDE!");
        if (!(rf-rc<0.005&&rc-rf<0.005)) failures++;
        if (cw>t[i].aw||ch>t[i].ah) { printf("   ATTENZIONE: mostra desktop!\n"); failures++; }
    }
    return failures;
}
